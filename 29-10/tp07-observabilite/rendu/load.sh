#!/usr/bin/env bash
# load.sh [N] [CONCURRENCE] : N requêtes sur l'API du TP04 depuis le réseau shop_front (hey, en conteneur).
#   MIX=1 : 10 % de POST /orders et 5 % de routes inexistantes (404) en plus des GET /products.
set -euo pipefail
N="${1:-1000}"; C="${2:-20}"; URL="${URL:-http://api:3000}"
hey() { docker run --rm --network shop_front williamyeh/hey:latest "$@"; }
hey -n "$N" -c "$C" "$URL/products" | grep -E 'Requests/sec|Status code|\[[0-9]{3}\]|99%|95%|Error' || true
if [[ ${MIX:-0} == 1 ]]; then
  hey -n $((N / 10)) -c 5 -m POST -T application/json -d '{"productId":1,"quantity":1}' "$URL/orders" | grep -E '\[[0-9]{3}\]' || true
  hey -n $((N / 20)) -c 5 "$URL/inexistant" | grep -E '\[[0-9]{3}\]' || true
fi
