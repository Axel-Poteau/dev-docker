#!/usr/bin/env bash
# verified-run.sh REGISTRY_IMAGE [options docker run...] [-- commande]
# Refuse de lancer une image dont la signature cosign n'est pas valide ; sinon lance l'image
# par DIGEST (celui qui a été vérifié), pour qu'un re-push du tag entre la vérif et le run soit sans effet.
set -euo pipefail
IMAGE="${1:?usage: $0 REGISTRY_IMAGE [options docker run...]}"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
COSIGN_PUB="${COSIGN_PUB:-$HERE/supply-chain/cosign.pub}"
REGISTRY_CA="${REGISTRY_CA:-$HERE/registry/certs/ca.crt}"
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"

if ! out=$(docker run --rm --network host -e DOCKER_CONFIG=/cfg -v "$DOCKER_CONFIG/config.json:/cfg/config.json:ro" \
      -e SSL_CERT_FILE=/ca.crt -v "$REGISTRY_CA:/ca.crt:ro" -v "$COSIGN_PUB:/cosign.pub:ro" \
      ghcr.io/sigstore/cosign/cosign:v2.4.1 verify --key /cosign.pub --insecure-ignore-tlog=true "$IMAGE" 2>&1); then
  echo "✘ signature invalide ou absente pour $IMAGE : exécution refusée" >&2
  grep -E '^Error' <<<"$out" >&2 || true
  exit 1
fi
digest=$(grep -o '"docker-manifest-digest":"sha256:[0-9a-f]*"' <<<"$out" | head -1 | cut -d'"' -f4)
echo "✔ signature vérifiée : ${IMAGE%:*}@$digest" >&2

# Insère l'image vérifiée (par digest) avant un éventuel "--" (commande du conteneur)
args=() cmd=()
while (($#)); do [[ "$1" == "--" ]] && { shift; cmd=("$@"); break; }; args+=("$1"); shift; done
exec docker run "${args[@]}" "${IMAGE%:*}@$digest" "${cmd[@]}"
