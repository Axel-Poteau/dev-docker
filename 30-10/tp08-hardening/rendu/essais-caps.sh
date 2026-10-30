#!/usr/bin/env bash
# essais-caps.sh — recherche par essai/erreur des capacités minimales (PostgreSQL, Traefik) et
# vérification du filtrage du proxy de socket. Volume neuf à chaque essai PostgreSQL.
set -uo pipefail
PG=postgres:16.4-alpine
FULL=(CHOWN DAC_OVERRIDE FOWNER SETGID SETUID)

pg_try() {   # pg_try <libellé> <options docker run…>
  local label=$1; shift
  docker volume rm -f caps-pg >/dev/null 2>&1
  docker run -d --name caps-pg -v caps-pg:/var/lib/postgresql/data -e POSTGRES_PASSWORD=essai \
    --cap-drop ALL --security-opt no-new-privileges "$@" $PG >/dev/null
  local verdict="ÉCHEC"
  for _ in $(seq 1 30); do
    if docker logs caps-pg 2>&1 | grep -q 'database system is ready to accept connections' \
       && docker exec caps-pg pg_isready -q 2>/dev/null; then verdict="OK"; break; fi
    [[ $(docker inspect -f '{{.State.Running}}' caps-pg) == false ]] && break
    sleep 1
  done
  printf '%-34s %-5s %s\n' "$label" "$verdict" \
    "$( [[ $verdict == OK ]] || docker logs caps-pg 2>&1 | grep -iE 'operation not permitted|permission denied|error|fatal' | head -1)"
  docker rm -f caps-pg >/dev/null; docker volume rm -f caps-pg >/dev/null
}

echo "## PostgreSQL démarré en root (entrypoint officiel : chown PGDATA puis su-exec postgres)"
pg_try "cap_drop ALL, aucune cap_add"
pg_try "+ ${FULL[*]}" $(printf -- '--cap-add %s ' "${FULL[@]}")
for drop in "${FULL[@]}"; do
  pg_try "  sans $drop" $(for c in "${FULL[@]}"; do [[ $c != "$drop" ]] && printf -- '--cap-add %s ' "$c"; done)
done
echo
echo "## PostgreSQL démarré directement en uid 70 (pas de chown, pas de changement d'utilisateur)"
pg_try "--user 70:70, aucune cap_add" --user 70:70

echo
echo "## Traefik : bind :80 sans NET_BIND_SERVICE, en nobody"
docker run --rm --cap-drop ALL --user 65534:65534 --read-only --entrypoint sh traefik:v3.1.7 -c \
  'traefik --entrypoints.web.address=:80 >/dev/null 2>&1 & sleep 2; id; netstat -ltn | grep ":80 "' 2>&1 | sed 's/^/  /'
echo
echo "## Proxy de socket : ce que voit Traefik via tcp://socket-proxy:2375 (${SOCKET_PROXY_LABEL:-config compose.hardened.yml})"
req() { docker run --rm --network shop_socket curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' -X "$1" "http://socket-proxy:2375$2"; }
for r in "GET /version" "GET /containers/json" "GET /events?since=0&until=1" "GET /images/json" "GET /secrets" \
         "GET /containers/shop-db-1/json" "GET /containers/shop-db-1/archive?path=/run/secrets/db_password" "GET /containers/shop-db-1/logs?stdout=1" "POST /containers/create" "POST /containers/shop-api-1/kill" "DELETE /containers/shop-api-1"; do
  printf '  %-52s → %s\n' "$r" "$(req $r)"
done
