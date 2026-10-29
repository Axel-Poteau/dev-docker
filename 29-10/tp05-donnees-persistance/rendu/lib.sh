# Paramètres communs à backup.sh / restore.sh / checksum.sh (sourcé)
# Par défaut : la stack du TP04 (projet "shop"). Surchargeable par variables d'environnement.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$HERE/../../tp04-compose-entreprise/rendu}"
COMPOSE="${COMPOSE:-docker compose}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${DB_USER:-shop}"
DB_NAME="${DB_NAME:-shop}"
VOLUME="${VOLUME:-shop_pgdata}"
BACKUP_DIR="${BACKUP_DIR:-$HERE/backups}"
KEEP="${KEEP:-7}"
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-alpine:3.21.2}"

compose() { (cd "$COMPOSE_DIR" && $COMPOSE "$@"); }
psql_db() { compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"; }
log()     { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
