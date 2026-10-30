# shellcheck shell=bash
# lib.sh — fonctions communes aux scripts d'exploitation (sourcé, pas exécuté)
# COMPOSE : commande compose de l'environnement (défaut : fichiers de COMPOSE_FILE / .env)
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPTS/.." || exit 1
[[ -f .env && -z ${COMPOSE_FILE:-} ]] && set -a && . ./.env && set +a
COMPOSE="${COMPOSE:-docker compose}"
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "ERREUR : $*" >&2; exit 1; }
# ops : conteneur jetable (client MariaDB + volumes) ; commande bash, mot de passe root lu dans le secret
ops()  { $COMPOSE --profile ops run --rm -T --no-deps ops "set -euo pipefail; export MYSQL_PWD=\$(cat /run/secrets/db_root_password); $1"; }
sql()  { ops "mariadb -h db -uroot -N -B geststock -e \"$1\""; }
