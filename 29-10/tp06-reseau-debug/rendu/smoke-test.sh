#!/usr/bin/env bash
# Critère de sortie de l'incident : catalogue servi par le front, cache Redis effectif, tout healthy.
set -euo pipefail
cd "$(dirname "$0")"
URL="${URL:-http://localhost:8081}"
fail() { echo "ÉCHEC : $*"; exit 1; }
[[ $(curl -s -m5 "$URL/health") == "front ok" ]] || fail "front /health"
docker compose exec -T redis sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password)" redis-cli del products' >/dev/null
first=$(curl -s -m5 -D - -o /tmp/products.$$ "$URL/products")
second=$(curl -s -m5 -D - -o /dev/null "$URL/products")
grep -q '^HTTP/1.1 200' <<<"$first" || fail "/products : $(head -1 <<<"$first")"
grep -qi '^X-Cache: MISS' <<<"$first" || fail "1er appel : MISS attendu"
grep -qi '^X-Cache: HIT' <<<"$second" || fail "2e appel : HIT attendu"
n=$(jq length /tmp/products.$$); rm -f /tmp/products.$$
(( n > 0 )) || fail "catalogue vide"
echo "OK /products : $n produits, MISS puis HIT"
bad=$(docker compose ps -a --format '{{.Name}} {{.Health}}' | awk '$2 != "healthy"')
[[ -z $bad ]] || fail "pas healthy : $bad"
echo "OK $(docker compose ps -q | wc -l) conteneurs healthy"
