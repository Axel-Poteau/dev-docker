#!/usr/bin/env bash
# setup.sh — prépare l'hôte preprod de TP et le contexte docker « preprod ».
#   1. clé SSH dédiée au déploiement (.ci/ssh, gitignoré)
#   2. démarre l'hôte (DinD + sshd, utilisateur deploy ∈ docker)
#   3. provisionne /srv/shop sur le serveur : secrets/ et db/ (JAMAIS dans git ni dans l'image)
#   4. docker context create preprod --docker host=ssh://deploy@preprod-lab
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOP="$(cd "$HERE/../.." && pwd)"
CI="$SHOP/.ci"
mkdir -p "$CI/ssh"; chmod 700 "$CI/ssh"
[[ -f $CI/ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C deploy@shop-ci -f "$CI/ssh/id_ed25519"

# Le client docker appelle « ssh » trouvé dans le PATH : un wrapper impose notre ssh_config
# (clé, port, known_hosts dédiés) sans toucher à ~/.ssh.
cat > "$CI/ssh/config" <<CFG
Host preprod-lab
  HostName 127.0.0.1
  Port 2222
  User deploy
  IdentityFile $CI/ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $CI/ssh/known_hosts
  StrictHostKeyChecking accept-new
CFG
mkdir -p "$CI/bin"
printf '#!/bin/sh\nexec /usr/bin/ssh -F "%s" "$@"\n' "$CI/ssh/config" > "$CI/bin/ssh"; chmod +x "$CI/bin/ssh"
export PATH="$CI/bin:$PATH"

docker compose -f "$HERE/compose.yml" up -d --build --wait 2>&1 | tail -1
for _ in $(seq 30); do ssh preprod-lab docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && break; sleep 1; done
echo "serveur : $(ssh preprod-lab 'echo "$(id -un) ∈ $(id -Gn)" ; docker version --format "docker {{.Server.Version}}"' | paste -sd' ')"

# Provisionnement hors git : le mot de passe est généré SUR le serveur et n'en sort jamais
ssh preprod-lab 'umask 077; mkdir -p /srv/shop/secrets /srv/shop/db/migrations
  [ -s /srv/shop/secrets/db_password.txt ] || { head -c 24 /dev/urandom | od -An -tx1 | tr -d " \n" > /srv/shop/secrets/db_password.txt; }
  chmod 644 /srv/shop/secrets/db_password.txt'   # lu par l'uid 1000 de l'API ; le dossier reste en 700
tar -C "$SHOP/db" -cf - . | ssh preprod-lab 'tar -C /srv/shop/db -xf -'
ssh preprod-lab 'ls -la /srv/shop /srv/shop/secrets | sed "s/^/  /"'

docker context inspect preprod >/dev/null 2>&1 || docker context create preprod --description "préprod de TP (DinD)" --docker host=ssh://deploy@preprod-lab >/dev/null
docker --context preprod info --format 'contexte preprod → {{.Name}} ({{.ServerVersion}}, {{.Containers}} conteneurs)'
echo "export PATH=\"$CI/bin:\$PATH\"   # à faire dans le shell pour utiliser --context preprod"
