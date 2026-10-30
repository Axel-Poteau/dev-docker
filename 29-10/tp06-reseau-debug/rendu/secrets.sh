#!/usr/bin/env sh
# Génère les secrets de la préprod s'ils n'existent pas (jamais versionnés : secrets/*.txt est gitignoré).
set -eu
cd "$(dirname "$0")"
mkdir -p secrets
for s in db_password redis_password; do
  [ -s "secrets/$s.txt" ] || { openssl rand -hex 24 > "secrets/$s.txt"; echo "secrets/$s.txt créé"; }
done
chmod 644 secrets/*.txt      # lus par postgres (uid 70), redis (999) et node (1000)
