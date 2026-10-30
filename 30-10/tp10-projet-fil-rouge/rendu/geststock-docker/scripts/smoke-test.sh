#!/usr/bin/env bash
# smoke-test.sh — test fonctionnel de bout en bout, via Traefik.
#   COMPOSE="docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml" ./scripts/smoke-test.sh
# MAILPIT_URL vide → contrôle du mail ignoré (prod : relais réel)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env && -z ${COMPOSE_FILE:-} ]] && set -a && . ./.env && set +a   # .env seulement hors CI
COMPOSE="${COMPOSE:-docker compose}"
BASE_URL="${BASE_URL:-http://localhost:${HTTP_PORT:-8090}}"
HOST="${APP_HOST:-geststock.localhost}"
MAILPIT_URL="${MAILPIT_URL-$BASE_URL}"
pass() { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✘\e[0m %s\n' "$1"; exit 1; }
web()  { curl -fsS -H "Host: $HOST" "$@"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "Smoke test GestStock sur $BASE_URL (Host: $HOST)"

# Traefik « healthy » ne veut pas dire « routes chargées » (découverte Docker + throttle 2 s) : on attend
for i in $(seq 30); do [[ $(web "$BASE_URL/?health" 2>/dev/null) == OK ]] && break; sleep 1; done
(( i < 30 )) && pass "?health : OK (base joignable, route prête en ${i}s)" || fail "?health"

# photo PNG 8x8 générée à la volée
python3 -c 'import zlib,struct,sys
def c(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
raw=b"".join(b"\x00"+b"\xff\x80\x00"*8 for _ in range(8))
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",8,8,8,2,0,0,0))+c(b"IDAT",zlib.compress(raw))+c(b"IEND",b""))' > "$tmp/photo.png"
name="smoke-$(date +%s)"
web -o "$tmp/post.html" -F "name=$name" -F qty=3 -F "photo=@$tmp/photo.png;type=image/png" "$BASE_URL/"
grep -q 'Article ajouté' "$tmp/post.html" && pass "POST article « $name » avec photo" || fail "POST article"

web -o "$tmp/list.html" "$BASE_URL/"
row=$(grep -F -A2 "$name" "$tmp/list.html") || fail "article absent de la liste"
photo=$(grep -oE '/uploads/p_[^"]+' <<<"$row") || fail "photo absente de la ligne"
ctype=$(web -o /dev/null -w '%{content_type}' "$BASE_URL$photo")
[[ $ctype == image/png ]] && pass "photo servie par l'alias /uploads ($photo, $ctype)" || fail "photo : $ctype"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE_URL/../lib/config.php")
[[ $code == 404 || $code == 403 || $code == 400 ]] && pass "code hors public/ non servi (lib/config.php → $code)" || fail "lib/config.php → $code"

id=$(grep -oE '\?delete=[0-9]+' <<<"$row" | cut -d= -f2)
web -o /dev/null "$BASE_URL/?delete=$id"
# (sortie capturée avant grep -q : avec pipefail, un grep -q qui sort tôt ferait échouer le pipe par SIGPIPE)
page=$(web "$BASE_URL/")
grep -qF "$name" <<<"$page" && fail "suppression" || pass "article $id supprimé"

logs=$($COMPOSE logs --no-log-prefix --since 2m app 2>/dev/null)
grep -qF "\"msg\":\"article ajouté: $name (3)\"" <<<"$logs" \
  && pass "log applicatif JSON sur stderr : article ajouté: $name" || fail "log applicatif absent de docker logs"

out=$($COMPOSE exec -T cron php bin/rapport.php 2>/dev/null) || fail "rapport.php"
pass "rapport à la demande : $(head -1 <<<"$out")"
if [[ -n $MAILPIT_URL ]]; then
  subject="Rapport stock $(date +%F)"
  for _ in 1 2 3 4 5; do
    n=$(curl -fsS -H 'Host: mail.localhost' "$MAILPIT_URL/api/v1/search?query=subject:%22$(date +%F)%22" | jq '.messages_count') && (( n > 0 )) && break
    sleep 1
  done
  (( n > 0 )) && pass "mail « $subject » reçu par Mailpit ($n)" || fail "aucun mail dans Mailpit"
fi
echo OK
