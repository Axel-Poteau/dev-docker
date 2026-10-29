#!/usr/bin/env bash
# upgrade-pg.sh — montée de version majeure PostgreSQL 14 -> 16 par dump/restore, sans toucher au volume d'origine.
#   checksum avant -> pg_dumpall + pg_dump -Fc -> arrêt PG14 (volume conservé) -> PG16 sur un NOUVEAU volume
#   -> restauration -> checksum après -> verdict (retour arrière automatique si différence)
set -euo pipefail
cd "$(dirname "$0")"
FROM_TAG="${FROM_TAG:-14.13-alpine}" FROM_VOLUME="${FROM_VOLUME:-pgdata}"
TO_TAG="${TO_TAG:-16.4-alpine}"     TO_VOLUME="${TO_VOLUME:-pgdata16}"
DUMP_DIR="${DUMP_DIR:-dumps}"
mkdir -p "$DUMP_DIR"
ts=$(date +%Y%m%d-%H%M%S)

log()      { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
use()      { printf 'PG_TAG=%s\nPG_VOLUME=%s\n' "$1" "$2" > .env; }   # version "active" de la stack
sql()      { docker compose exec -T db psql -U shop -d shop -v ON_ERROR_STOP=1 "$@"; }
checksum() { sql -tA -F ' ' -c "SELECT count(*), md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"; }

use "$FROM_TAG" "$FROM_VOLUME"
docker compose up -d --wait db >/dev/null 2>&1
log "version source : $(sql -tAc 'SHOW server_version')"
before=$(checksum); log "checksum avant  : $before"

log "pg_dumpall (rôles + toutes les bases) et pg_dump -Fc shop"
docker compose exec -T db pg_dumpall -U shop > "$DUMP_DIR/dumpall-$ts.sql"
docker compose exec -T db pg_dumpall -U shop --globals-only > "$DUMP_DIR/globals-$ts.sql"
docker compose exec -T db pg_dump -U shop -Fc shop > "$DUMP_DIR/shop-$ts.dump"
ls -l "$DUMP_DIR"/*-"$ts".* | awk '{print "         " $5 " " $9}'

t0=$(date +%s)
log "arrêt de PostgreSQL ${FROM_TAG%%-*} (le volume $FROM_VOLUME est conservé) — début de l'indisponibilité"
docker compose stop db >/dev/null 2>&1

log "démarrage de PostgreSQL ${TO_TAG%%-*} sur le volume neuf $TO_VOLUME"
use "$TO_TAG" "$TO_VOLUME"
docker compose up -d --wait db >/dev/null 2>&1
log "version cible  : $(sql -tAc 'SHOW server_version')"

log "restauration : rôles (globals) puis base shop (pg_restore)"
sql -q -v ON_ERROR_STOP=0 < "$DUMP_DIR/globals-$ts.sql" 2>&1 | grep -v 'already exists' || true
docker compose exec -T db pg_restore -U shop -d shop --no-owner --exit-on-error < "$DUMP_DIR/shop-$ts.dump"
docker compose exec -T db vacuumdb -U shop -d shop --analyze-only --quiet   # pg_dump ne transporte pas les statistiques
t1=$(date +%s)
log "fin de l'indisponibilité : $((t1 - t0)) s"

after=$(checksum); log "checksum après  : $after"
if [[ "$before" == "$after" ]]; then
  log "VERDICT : OK, données identiques. PostgreSQL ${TO_TAG%%-*} actif ($TO_VOLUME) ; $FROM_VOLUME conservé pour le retour arrière."
else
  log "VERDICT : ÉCHEC (checksums différents) -> retour arrière automatique sur PostgreSQL ${FROM_TAG%%-*}"
  docker compose stop db >/dev/null 2>&1
  use "$FROM_TAG" "$FROM_VOLUME"
  docker compose up -d --wait db >/dev/null 2>&1
  exit 1
fi
