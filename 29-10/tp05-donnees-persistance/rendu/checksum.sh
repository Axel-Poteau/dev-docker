#!/usr/bin/env bash
# checksum.sh — empreinte des commandes (même requête que starter/seed.sh) : "<nb commandes> <md5>"
set -euo pipefail
source "$(dirname "$0")/lib.sh"
psql_db -tA -F ' ' -c \
  "SELECT count(*), md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"
