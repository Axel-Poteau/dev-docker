#!/usr/bin/env bash
# smoke-test.sh — vérifie la stack de bout en bout, en passant par le reverse proxy.
#   COMPOSE="docker compose -f compose.yml -f compose.prod.yml" ./smoke-test.sh   (prod)
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] && set -a && . ./.env && set +a
COMPOSE="${COMPOSE:-docker compose}"
BASE_URL="${BASE_URL:-http://localhost:${HTTP_PORT:-80}}"
API_HOST="${API_HOST:-api.localhost}"
PRODUCT_ID="${PRODUCT_ID:-1}"

pass() { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✘\e[0m %s\n' "$1"; exit 1; }
api()  { curl -fsS -H "Host: $API_HOST" "$@"; }

echo "Smoke test sur $BASE_URL (Host: $API_HOST)"

ready=$(api "$BASE_URL/ready") || fail "/ready ne répond pas"
[[ $(jq -r '.status + " " + .checks.db + " " + .checks.redis' <<<"$ready") == "ready ok ok" ]] \
  && pass "/ready : $ready" || fail "/ready : $ready"

api -o /dev/null "$BASE_URL/products"
cache=$(api -D - -o /dev/null "$BASE_URL/products" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache" {print $2}')
[[ "$cache" == "HIT" ]] && pass "/products servi depuis Redis (X-Cache: HIT)" || fail "/products : X-Cache=$cache (HIT attendu)"

order=$(api -X POST -H 'Content-Type: application/json' -d "{\"productId\":$PRODUCT_ID,\"quantity\":2}" "$BASE_URL/orders") \
  || fail "POST /orders"
pass "commande créée : $(jq -c '{id, productId, status}' <<<"$order")"

# Le worker consomme orders:queue et passe la commande en "confirmed"
order_id=$($COMPOSE exec -T db psql -U shop -d shop -tAc \
  "SELECT max(id) FROM orders WHERE product_id = $PRODUCT_ID")
for _ in $(seq 1 20); do
  status=$($COMPOSE exec -T db psql -U shop -d shop -tAc "SELECT status FROM orders WHERE id = $order_id")
  [[ "$status" == "confirmed" ]] && break
  sleep 0.5
done
[[ "$status" == "confirmed" ]] && pass "commande $order_id confirmée par le worker" \
  || fail "commande $order_id toujours '$status' après 10 s"

echo "OK"
