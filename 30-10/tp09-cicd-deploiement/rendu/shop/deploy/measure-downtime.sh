#!/usr/bin/env bash
# measure-downtime.sh [durée_s] — ~RATE req/s sur /health via le reverse proxy, puis bilan.
#   ./deploy/measure-downtime.sh 40          (Ctrl-C arrête plus tôt, le bilan s'affiche quand même)
# Variables : URL (http://127.0.0.1:18000/health), HOST (api.localhost), RATE (100), TIMEOUT (2 s)
set -uo pipefail
DURATION="${1:-30}"
URL="${URL:-http://127.0.0.1:18000/health}"
HOST="${HOST:-api.localhost}"
RATE="${RATE:-100}"
TIMEOUT="${TIMEOUT:-2}"
BATCH=$((RATE / 10))                       # un lot toutes les 100 ms
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT

summary() {
  wait
  local total ok
  total=$(wc -l < "$OUT"); ok=$(awk '$2 == 200' "$OUT" | wc -l)
  echo
  echo "requêtes : $total   succès : $ok   ÉCHECS : $((total - ok))"
  awk '{c[$2]++} END {for (k in c) printf "  HTTP %s : %d\n", (k == "000" ? "000 (connexion/timeout)" : k), c[k]}' "$OUT" | sort
  if (( total > ok )); then
    awk '$2 != 200 {print $1}' "$OUT" | sort -n | awk 'NR == 1 {f = $1} {l = $1} END {printf "  fenêtre d'"'"'échec : %.2f s (du %s au %s)\n", l - f, strftime("%T", f), strftime("%T", l)}'
  fi
  exit $(( total > ok ))
}
trap summary INT TERM

echo "$(date +%T) ${RATE} req/s sur $URL (Host: $HOST) pendant ${DURATION}s"
end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  for _ in $(seq "$BATCH"); do
    { t=$EPOCHREALTIME; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -H "Host: $HOST" "$URL"); echo "$t $code" >> "$OUT"; } &
  done
  sleep 0.1
done
summary
