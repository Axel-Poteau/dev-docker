#!/usr/bin/env bash
# backup.sh — sauvegarde cohérente : base (mariadb-dump --single-transaction, à chaud) + photos + sommes.
#   ./scripts/backup.sh            → backups/AAAAMMJJ-HHMMSS/{db.sql.gz,uploads.tar.gz,SHA256SUMS,meta.txt}
#   KEEP=7 : rotation (le legacy a rempli son disque en mars faute de rotation)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
KEEP="${KEEP:-7}"
ts=$(date +%Y%m%d-%H%M%S); dir="backups/$ts"; mkdir -p "$dir"
ops "mariadb-dump -h db -uroot --single-transaction --routines --triggers --default-character-set=utf8mb4 geststock | gzip -9" > "$dir/db.sql.gz"
ops "tar -C /uploads -czf - ." > "$dir/uploads.tar.gz"
{
  echo "date=$(date -Iseconds)"
  echo "image=$($COMPOSE images app --format json 2>/dev/null | jq -r '.[0] | "\(.Repository):\(.Tag)"' 2>/dev/null || echo inconnu)"
  echo "items=$(sql 'SELECT count(*) FROM items')"
  echo "photos=$(tar -tzf "$dir/uploads.tar.gz" | grep -vc '/$')"
} > "$dir/meta.txt"
( cd "$dir" && sha256sum db.sql.gz uploads.tar.gz meta.txt > SHA256SUMS )
gzip -t "$dir/db.sql.gz" && tar -tzf "$dir/uploads.tar.gz" >/dev/null || die "archive corrompue"
log "sauvegarde $dir : $(du -sh "$dir" | cut -f1), $(grep -E '^(items|photos)=' "$dir/meta.txt" | paste -sd' ')"
ls -1d backups/2*/ 2>/dev/null | head -n -"$KEEP" | xargs -r rm -rf
echo "$dir"
