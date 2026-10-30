#!/usr/bin/env bash
# rolling-update.sh — met à jour l'API sans interruption, un réplica à la fois.
#   DOCKER_CONTEXT=preprod VERSION=sha-abc1234 ./deploy/rolling-update.sh
#   VERSION=<ancien tag> ./deploy/rolling-update.sh          → rollback (même mécanique)
#
# Pour chaque ancien réplica : +1 réplica neuf → attente « healthy » (HEALTHCHECK + start_period)
# → Traefik l'ajoute (il ignore les conteneurs starting/unhealthy) → arrêt propre de l'ancien
# (SIGTERM, server.close(), stop -t 15) → suppression. Premier déploiement : simple « up --wait ».
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?VERSION requise (ex. sha-abc1234 ou 1.2.0)}"
CONTEXT="${DOCKER_CONTEXT:-$(docker context show)}"
ENV_FILE="deploy/env/$CONTEXT.env"; [[ -f $ENV_FILE ]] || ENV_FILE=.env
REPLICAS="${REPLICAS:-2}"
STOP_TIMEOUT="${STOP_TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
DRAIN_DELAY="${DRAIN_DELAY:-3}"     # > providersThrottleDuration (2 s) de Traefik
export VERSION
COMPOSE=(docker compose --env-file "$ENV_FILE" -f compose.yml -f compose.prod.yml)
PROJECT=shop
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
api_ids() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=api | sort; }
name() { docker inspect -f '{{.Name}}' "$1" | cut -c2-; }
wait_healthy() {
  local id=$1 t=0 st
  while (( t < HEALTH_TIMEOUT )); do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$id")
    [[ $st == healthy ]] && return 0
    [[ $st == unhealthy ]] && return 1
    sleep 1; t=$((t + 1))
  done; return 1
}
SECONDS=0
log "contexte=$CONTEXT version=$VERSION réplicas=$REPLICAS"
"${COMPOSE[@]}" pull -q api worker
target=$("${COMPOSE[@]}" config --images | grep '/shopapi:')

mapfile -t old < <(api_ids)
if (( ${#old[@]} == 0 )); then
  log "premier déploiement : stack complète"
  "${COMPOSE[@]}" up -d --wait
  log "terminé en ${SECONDS}s"; exit 0
fi
# dépendances (db, redis, proxy) : démarrées si absentes, jamais recréées ici
"${COMPOSE[@]}" up -d --wait --no-recreate proxy db redis

count=${#old[@]}
for id in "${old[@]}"; do
  if [[ $(docker inspect -f '{{.Config.Image}}' "$id") == "$target" ]]; then
    log "$(name "$id") déjà en $VERSION : conservé"; continue
  fi
  before=$(api_ids)
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "api=$((count + 1))" api 2>/dev/null
  new=$(comm -13 <(echo "$before") <(api_ids))
  [[ -n $new ]] || { log "aucun nouveau réplica créé"; exit 1; }
  log "nouveau réplica $(name "$new") ($VERSION) : attente healthy…"
  if ! wait_healthy "$new"; then
    log "ÉCHEC : $(name "$new") n'est pas healthy → suppression, l'ancienne version reste en service"
    docker logs --tail 20 "$new" >&2 || true
    docker rm -f "$new" >/dev/null; exit 1
  fi
  log "$(name "$new") healthy ; Traefik le prend en compte (${DRAIN_DELAY}s)"
  sleep "$DRAIN_DELAY"
  log "arrêt propre de $(name "$id") (SIGTERM, ${STOP_TIMEOUT}s max)"
  docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null && docker rm "$id" >/dev/null
done
# s'il manquait des réplicas (REPLICAS > actuel), on complète
(( count < REPLICAS )) && "${COMPOSE[@]}" up -d --no-deps --no-recreate --wait --scale "api=$REPLICAS" api

log "worker (consommateur de file : une courte coupure ne perd aucun message)"
"${COMPOSE[@]}" up -d --no-deps --wait worker 2>/dev/null
"${COMPOSE[@]}" ps --format '  {{.Name}}\t{{.Image}}\t{{.Status}}' api worker
log "terminé en ${SECONDS}s"
