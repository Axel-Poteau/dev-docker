#!/usr/bin/env bash
# backup.sh [--raw]
#   par défaut : dump logique pg_dump -Fc horodaté (base en ligne, cohérent : snapshot MVCC)
#   --raw      : en plus, copie brute du volume (tar via un conteneur alpine), base ARRÊTÉE le temps de la copie
# Rétention : garde les $KEEP dernières sauvegardes de chaque type. Aucun client PostgreSQL requis sur l'hôte.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
RAW=false; [[ "${1:-}" == "--raw" ]] && RAW=true

mkdir -p "$BACKUP_DIR"
ts=$(date +%Y%m%d-%H%M%S)

# ---- 1. Dump logique (format custom : compressé, restauration sélective / parallèle)
dump="$BACKUP_DIR/$DB_NAME-$ts.dump"
log "pg_dump -Fc $DB_NAME -> $(basename "$dump")"
compose exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$dump.part"
# un dump non relisible n'est pas une sauvegarde : on vérifie la table des matières avant de valider
entries=$(compose exec -T "$DB_SERVICE" pg_restore -l < "$dump.part" | grep -vc '^;')
(( entries > 0 )) || { log "dump invalide"; rm -f "$dump.part"; exit 1; }
mv "$dump.part" "$dump"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$dump")" > "$(basename "$dump").sha256")
log "OK : $(du -h "$dump" | cut -f1), $entries objets"

# ---- 2. Sauvegarde brute du volume (à froid)
if $RAW; then
  tarball="$BACKUP_DIR/$VOLUME-$ts.tar.gz"
  log "arrêt de $DB_SERVICE pour une copie cohérente du volume $VOLUME"
  compose stop "$DB_SERVICE" >/dev/null
  trap 'compose start "$DB_SERVICE" >/dev/null' EXIT
  docker run --rm -v "$VOLUME:/data:ro" -v "$BACKUP_DIR:/backup" "$TOOLBOX_IMAGE" \
    tar -czf "/backup/$(basename "$tarball")" -C /data .
  compose up -d --wait "$DB_SERVICE" >/dev/null 2>&1; trap - EXIT
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256")
  log "OK : $(basename "$tarball") $(du -h "$tarball" | cut -f1) ; $DB_SERVICE redémarré"
fi

# ---- 3. Rétention
for pattern in "$DB_NAME-*.dump" "$VOLUME-*.tar.gz"; do
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
    log "rétention : suppression de $(basename "$old")"; rm -f "$old" "$old.sha256"
  done
done
echo "$dump"
