#!/usr/bin/env bash
# setup-exporter.sh — crée/actualise l'utilisateur MariaDB « exporter » (idempotent, rejouable après rotation)
# Droits minimaux de mysqld-exporter : PROCESS, REPLICATION CLIENT, SELECT sur performance_schema.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ops 'P=$(cat /run/secrets/db_exporter_password); mariadb -h db -uroot -e "
  CREATE USER IF NOT EXISTS exporter@\`%\` IDENTIFIED BY \"$P\" WITH MAX_USER_CONNECTIONS 3;
  ALTER USER exporter@\`%\` IDENTIFIED BY \"$P\";
  GRANT PROCESS, REPLICATION CLIENT ON *.* TO exporter@\`%\`;
  GRANT SELECT ON performance_schema.* TO exporter@\`%\`;"'
log "utilisateur exporter prêt"
