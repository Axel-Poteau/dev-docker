#!/usr/bin/env bash
# migrate-legacy.sh DUMP.sql UPLOADS.tar.gz — reprise des données du serveur legacy (Debian 10, MariaDB 10.3)
#   1. vérifie les sommes de contrôle livrées (SHA256SUMS à côté du dump)
#   2. sauvegarde de sécurité de l'état actuel (backup.sh)
#   3. arrête app + cron (aucune écriture pendant la reprise)
#   4. importe le dump (le dump contient DROP TABLE / CREATE TABLE : la table items est remplacée)
#   5. copie les photos dans le volume uploads (propriétaire www-data, 33:33)
#   6. contrôles : nombre d'articles, chaque photo référencée existe ; redémarrage
set -euo pipefail
source "$(dirname "$0")/lib.sh"
DUMP="${1:?usage: $0 DUMP.sql UPLOADS.tar.gz}"; UPLOADS="${2:?usage: $0 DUMP.sql UPLOADS.tar.gz}"
[[ -f $DUMP && -f $UPLOADS ]] || die "fichier introuvable"
SUMS="$(dirname "$DUMP")/SHA256SUMS"
if [[ -f $SUMS ]]; then ( cd "$(dirname "$DUMP")" && sha256sum -c --quiet SHA256SUMS ) && log "sommes de contrôle OK"
else log "pas de SHA256SUMS fourni : intégrité non vérifiable"; fi

expected=$(grep -oE "^INSERT INTO \`items\` VALUES .*" "$DUMP" | grep -oE "\),\(|\);$" | wc -l)
log "dump : $(head -1 "$DUMP" | sed 's/^-- //') — $expected articles"

log "sauvegarde de sécurité avant reprise"
"$SCRIPTS/backup.sh" >/dev/null

log "arrêt de app et cron"
$COMPOSE stop app cron >/dev/null 2>&1

log "import du dump"
ops "mariadb -h db -uroot geststock" < "$DUMP"
log "photos → volume uploads"
ops "tar -xzf - -C /uploads && chown -R 33:33 /uploads && chmod 644 /uploads/* && ls /uploads | wc -l" < "$UPLOADS" | sed 's/^/  fichiers dans le volume : /'

got=$(sql "SELECT count(*) FROM items")
[[ $got == "$expected" ]] && log "contrôle : $got articles importés" || die "$got articles en base, $expected attendus"
missing=$(ops "mariadb -h db -uroot -N -B geststock -e 'SELECT photo FROM items WHERE photo IS NOT NULL' | while read -r p; do [ -f \"/uploads/\$p\" ] || echo \"\$p\"; done")
[[ -z $missing ]] && log "contrôle : toutes les photos référencées sont présentes" || die "photos manquantes : $missing"

log "redémarrage de app et cron"
$COMPOSE up -d --wait app cron >/dev/null 2>&1
log "reprise terminée"
