#!/usr/bin/env bash
# Génère une CA interne + un certificat serveur pour le registre (SAN registry.local, localhost, 127.0.0.1)
# puis installe la CA côté client Docker.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
DAYS_CA=3650 DAYS_SRV=825

if [[ ! -f certs/ca.key ]]; then
  openssl genrsa -out certs/ca.key 4096
  openssl req -x509 -new -key certs/ca.key -sha256 -days "$DAYS_CA" \
    -subj "/O=Shop SAS/CN=Shop SAS Internal CA" -out certs/ca.crt
fi

openssl genrsa -out certs/registry.key 2048
openssl req -new -key certs/registry.key -subj "/O=Shop SAS/CN=registry.local" -out certs/registry.csr
cat > certs/registry.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:registry.local,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in certs/registry.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -days "$DAYS_SRV" -sha256 -extfile certs/registry.ext -out certs/registry.crt
rm -f certs/registry.csr certs/registry.ext
chmod 644 certs/registry.key   # lu par l'utilisateur du conteneur registry

# Confiance côté client Docker : /etc/docker/certs.d (Docker Engine) ou ~/.docker/certs.d (Docker Desktop)
for host in registry.local:5000 localhost:5000; do
  if [[ -w /etc/docker/certs.d || $(id -u) -eq 0 ]]; then
    install -D -m 644 certs/ca.crt "/etc/docker/certs.d/$host/ca.crt"
  else
    install -D -m 644 certs/ca.crt "$HOME/.docker/certs.d/$host/ca.crt"
  fi
done

grep -q 'registry.local' /etc/hosts || echo "⚠ ajoutez « 127.0.0.1 registry.local » à /etc/hosts (sudo)"
openssl x509 -in certs/registry.crt -noout -subject -issuer -ext subjectAltName
