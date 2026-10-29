#!/usr/bin/env bash
# Crée auth/htpasswd (bcrypt) avec les comptes ci et dev. Mots de passe lus dans l'environnement
# (valeurs par défaut de formation uniquement).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p auth
CI_PASSWORD="${CI_PASSWORD:-ci-push-2024}"
DEV_PASSWORD="${DEV_PASSWORD:-dev-pull-2024}"
{
  docker run --rm httpd:2.4.62-alpine htpasswd -Bbn -C 10 ci "$CI_PASSWORD"
  docker run --rm httpd:2.4.62-alpine htpasswd -Bbn -C 10 dev "$DEV_PASSWORD"
} | grep -v '^$' > auth/htpasswd
cut -d: -f1,2 auth/htpasswd | sed 's/:\(\$2y\$10\$.\{8\}\).*/:\1…/'
