#!/usr/bin/env bash
# restore.sh backups/AAAAMMJJ-HHMMSS — restauration complète (base + photos). DESTRUCTIF pour l'état courant.
#   FORCE=1 pour ne pas demander de confirmation (scripts, tests)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dir="${1:?usage: $0 backups/<horodatage>}"; dir="${dir%/}"
[[ -f $dir/SHA256SUMS ]] || die "$dir n'est pas une sauvegarde"
( cd "$dir" && sha256sum -c --quiet SHA256SUMS ) || die "sommes de contrôle invalides : sauvegarde corrompue"
log "sauvegarde $dir vérifiée ($(grep -E '^(date|items|photos)=' "$dir/meta.txt" | paste -sd' '))"
if [[ ${FORCE:-0} != 1 ]]; then
  read -r -p "Écraser la base et les photos actuelles ? [y/N] " r; [[ $r == y ]] || die "annulé"
fi
log "arrêt de app et cron"
$COMPOSE stop app cron >/dev/null 2>&1
log "restauration de la base"
gunzip -c "$dir/db.sql.gz" | ops "mariadb -h db -uroot geststock"
log "restauration des photos (le volume est vidé avant)"
ops "find /uploads -mindepth 1 -delete && tar -xzf - -C /uploads && chown -R 33:33 /uploads" < "$dir/uploads.tar.gz"
expected=$(sed -n 's/^items=//p' "$dir/meta.txt"); got=$(sql 'SELECT count(*) FROM items')
[[ $got == "$expected" ]] || die "$got articles après restauration, $expected attendus"
log "redémarrage"
$COMPOSE up -d --wait app cron >/dev/null 2>&1
log "restauration terminée : $got articles"
