#!/usr/bin/env bash
# rotate-db-password.sh — rotation du mot de passe MariaDB de l'application, sans redémarrage.
# Le secret est un bind mount du FICHIER : on le réécrit EN PLACE (même inode). Un « mv » créerait un
# nouvel inode que les conteneurs ne verraient qu'après recréation. config.php relit le secret à chaque
# requête : ALTER USER puis réécriture du fichier, quelques millisecondes d'écart.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
file="${SECRETS_DIR:-./secrets}/db_password.txt"
[[ -f $file ]] || die "$file introuvable"
new=$(openssl rand -hex 24)
inode=$(stat -c %i "$file")
log "ALTER USER geststock (nouveau mot de passe généré, jamais affiché)"
# exec dans db (secret root déjà monté) plutôt qu'un conteneur ops : la commande rend la main ~10× plus vite,
# ce qui réduit d'autant la fenêtre ALTER USER → réécriture du fichier (cf. rotation-secret.txt).
# -e NEWPW sans valeur : transmis par l'environnement, jamais sur une ligne de commande (visible dans ps)
NEWPW="$new" $COMPOSE exec -T -e NEWPW db sh -c \
  'export MYSQL_PWD=$(cat /run/secrets/db_root_password); [ -n "$NEWPW" ] || exit 9
   mariadb -uroot -e "ALTER USER geststock@\`%\` IDENTIFIED BY \"$NEWPW\""'
printf '%s\n' "$new" > "$file"          # même inode : visible immédiatement dans les conteneurs
[[ $(stat -c %i "$file") == "$inode" ]] || die "inode changé : recréer app et cron"
log "secret réécrit en place (inode $inode)"
[[ $($COMPOSE exec -T cron php -r 'require "lib/db.php"; echo db()->query("SELECT 1")->fetchColumn();' 2>/dev/null) == 1 ]] \
  && log "connexion applicative OK avec le nouveau mot de passe" || die "connexion applicative KO"
