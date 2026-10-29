#!/usr/bin/env bash
# restore.sh FICHIER
#   *.dump   : pg_restore --clean dans la base existante (une transaction : tout ou rien)
#   *.tar.gz : restauration brute du volume (base arrêtée, volume vidé puis réhydraté)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
file="$(realpath "${1:?usage: restore.sh FICHIER (.dump | .tar.gz)}")"

if [[ -f "$file.sha256" ]]; then
  (cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256") || { log "checksum invalide"; exit 1; }
  log "intégrité vérifiée (sha256)"
fi

case "$file" in
  *.dump)
    compose up -d --wait "$DB_SERVICE" >/dev/null 2>&1
    log "pg_restore --clean --if-exists --single-transaction $(basename "$file")"
    compose exec -T "$DB_SERVICE" pg_restore -U "$DB_USER" -d "$DB_NAME" \
      --clean --if-exists --no-owner --single-transaction < "$file"
    ;;
  *.tar.gz)
    log "arrêt de $DB_SERVICE, restauration brute du volume $VOLUME"
    compose stop "$DB_SERVICE" >/dev/null
    docker run --rm -v "$VOLUME:/data" -v "$(dirname "$file"):/backup:ro" "$TOOLBOX_IMAGE" \
      sh -c "find /data -mindepth 1 -delete && tar -xzf '/backup/$(basename "$file")' -C /data"
    compose up -d --wait "$DB_SERVICE" >/dev/null 2>&1
    ;;
  *) log "format inconnu : $file"; exit 2 ;;
esac
log "restauration terminée"
