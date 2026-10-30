#!/usr/bin/env bash
# hardened.sh <commande compose…> — stack TP04 (base + prod) + surcharge durcie.
#   ./hardened.sh up -d --wait --pull never
#   ./hardened.sh smoke          smoke test du TP04 sur la stack durcie
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="${TP04_DIR:-$HERE/../../../29-10/tp04-compose-entreprise/rendu}"
COMPOSE="docker compose -f $T/compose.yml -f $T/compose.prod.yml -f $HERE/compose.hardened.yml"
if [[ "${1:-}" == smoke ]]; then COMPOSE="$COMPOSE" exec "$T/smoke-test.sh"; fi
exec $COMPOSE "$@"
