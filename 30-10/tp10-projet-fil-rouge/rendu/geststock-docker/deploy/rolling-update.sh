#!/usr/bin/env bash
# rolling-update.sh — met à jour GestStock sans interruption, un réplica à la fois (repris du TP09).
#   VERSION=sha-abc1234 ./deploy/rolling-update.sh            déploiement / rollback (tag précédent)
#   FORCE=1 VERSION=<tag courant> ./deploy/rolling-update.sh  redémarrage progressif (rotation de secret)
# Compose : COMPOSE_FILE (défaut : prod + durci) ; DOCKER_CONTEXT pour un hôte distant.
# Par réplica : +1 neuf → healthy (HEALTHCHECK ?health) → Traefik l'ajoute → arrêt gracieux de l'ancien
# après un drain (/tmp/drain → ?health en 503 → retiré du pool Traefik), puis SIGWINCH : Apache termine
# les requêtes en cours.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?VERSION requise (ex. sha-abc1234)}"
export VERSION COMPOSE_FILE="${COMPOSE_FILE:-compose.yml:compose.prod.yml:compose.hardened.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-geststock}"
SERVICE=app
REPLICAS="${REPLICAS:-2}"; STOP_TIMEOUT="${STOP_TIMEOUT:-20}"; HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"; DRAIN_DELAY="${DRAIN_DELAY:-3}"; DRAIN_TIME="${DRAIN_TIME:-4}"   # > healthcheck Traefik (2 s)
COMPOSE=(docker compose)
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
ids() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE" | sort; }
name() { docker inspect -f '{{.Name}}' "$1" | cut -c2-; }
wait_healthy() {
  local t=0 st
  while (( t < HEALTH_TIMEOUT )); do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$1"); [[ $st == healthy ]] && return 0; [[ $st == unhealthy ]] && return 1
    sleep 1; t=$((t + 1))
  done; return 1
}
SECONDS=0
log "projet=$PROJECT version=$VERSION réplicas=$REPLICAS"
"${COMPOSE[@]}" pull -q --ignore-pull-failures "$SERVICE" cron 2>/dev/null || true
target=$("${COMPOSE[@]}" config --images | grep '/geststock:' | head -1)
docker image inspect "$target" >/dev/null 2>&1 || { log "image $target introuvable"; exit 1; }

mapfile -t old < <(ids)
if (( ${#old[@]} == 0 )); then
  log "premier déploiement : stack complète"; "${COMPOSE[@]}" up -d --wait; log "terminé en ${SECONDS}s"; exit 0
fi
# Garde-fou (TP09) : des labels Traefik différents entre ancienne et nouvelle version font supprimer
# le service par Traefik tant qu'elles cohabitent (404 pendant tout le rolling).
traefik_labels() { jq -S 'with_entries(select(.key | startswith("traefik.")))'; }
new_labels=$("${COMPOSE[@]}" config --format json | jq ".services.$SERVICE.labels" | traefik_labels)
old_labels=$(docker inspect -f '{{json .Config.Labels}}' "${old[0]}" | traefik_labels)
if [[ $new_labels != "$old_labels" && ${ALLOW_LABEL_CHANGE:-0} != 1 ]]; then
  log "REFUS : labels Traefik modifiés (cohabitation impossible sans coupure) :"
  diff <(echo "$old_labels") <(echo "$new_labels") | grep '^[<>]' | sed 's/^/    /' >&2 || true
  exit 3
fi
"${COMPOSE[@]}" up -d --wait --no-recreate proxy socket-proxy db

count=${#old[@]}
for id in "${old[@]}"; do
  if [[ $(docker inspect -f '{{.Config.Image}}' "$id") == "$target" && ${FORCE:-0} != 1 ]]; then
    log "$(name "$id") déjà en $VERSION : conservé"; continue
  fi
  before=$(ids)
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "$SERVICE=$((count + 1))" "$SERVICE" 2>/dev/null
  new=$(comm -13 <(echo "$before") <(ids)); [[ -n $new ]] || { log "aucun réplica créé"; exit 1; }
  log "nouveau réplica $(name "$new") : attente healthy…"
  if ! wait_healthy "$new"; then
    log "ÉCHEC : $(name "$new") pas healthy → supprimé, l'ancienne version reste en service"
    docker logs --tail 20 "$new" >&2 || true; docker rm -f "$new" >/dev/null; exit 1
  fi
  log "$(name "$new") healthy ; prise en compte par Traefik (${DRAIN_DELAY}s)"; sleep "$DRAIN_DELAY"
  # drain : ?health en 503 (règle Apache), Traefik le retire du pool avant qu'Apache ne ferme ses sockets
  docker exec "$id" touch /tmp/drain 2>/dev/null && log "drain de $(name "$id") (${DRAIN_TIME}s)" && sleep "$DRAIN_TIME"
  log "arrêt gracieux de $(name "$id")"
  docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null && docker rm "$id" >/dev/null
done
(( count < REPLICAS )) && "${COMPOSE[@]}" up -d --no-deps --no-recreate --wait --scale "$SERVICE=$REPLICAS" "$SERVICE"
log "cron (rapport en cours terminé avant arrêt : SIGTERM, 60 s)"
"${COMPOSE[@]}" up -d --no-deps --wait cron 2>/dev/null
"${COMPOSE[@]}" ps --format '  {{.Name}}\t{{.Image}}\t{{.Status}}' "$SERVICE" cron
log "terminé en ${SECONDS}s"
