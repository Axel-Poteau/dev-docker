#!/usr/bin/env bash
# Petit client de l'API Registry v2 (curl + jq uniquement).
#   ./registry-api.sh repos
#   ./registry-api.sh tags REPO
#   ./registry-api.sh digest REPO TAG
#   ./registry-api.sh created REPO TAG
#   ./registry-api.sh delete REPO DIGEST
# Variables : REGISTRY (défaut registry.local:5000), REGISTRY_USER/REGISTRY_PASSWORD,
#             REGISTRY_CACERT (défaut registry/certs/ca.crt), REGISTRY_RESOLVE (ex. 127.0.0.1 si pas d'entrée /etc/hosts)
set -euo pipefail

REGISTRY="${REGISTRY:-registry.local:5000}"
REGISTRY_USER="${REGISTRY_USER:-dev}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-dev-pull-2024}"
REGISTRY_CACERT="${REGISTRY_CACERT:-$(dirname "$0")/registry/certs/ca.crt}"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

api() {
  local resolve=()
  [[ -n "${REGISTRY_RESOLVE:-}" ]] && resolve=(--resolve "${REGISTRY}:${REGISTRY_RESOLVE}")
  curl -fsS "${resolve[@]}" --cacert "$REGISTRY_CACERT" -u "$REGISTRY_USER:$REGISTRY_PASSWORD" "$@"
}

repos()   { api "https://$REGISTRY/v2/_catalog?n=1000" | jq -r '.repositories[]'; }
tags()    { api "https://$REGISTRY/v2/$1/tags/list" | jq -r '.tags // [] | .[]'; }

# Digest d'un tag : en-tête Docker-Content-Digest d'un HEAD sur le manifeste (le bon Accept est indispensable,
# sinon le registre renvoie/convertit un autre format et le digest ne correspond pas)
digest() {
  api -I -H "Accept: $ACCEPT" "https://$REGISTRY/v2/$1/manifests/$2" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}'
}

# Date de création d'une image : champ .created de son blob de configuration
created() {
  local manifest config
  manifest=$(api -H "Accept: $ACCEPT" "https://$REGISTRY/v2/$1/manifests/$2")
  if jq -e '.manifests' >/dev/null <<<"$manifest"; then   # index multi-plateforme : on prend la 1re image
    local sub; sub=$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest' <<<"$manifest")
    manifest=$(api -H "Accept: $ACCEPT" "https://$REGISTRY/v2/$1/manifests/$sub")
  fi
  config=$(jq -r '.config.digest' <<<"$manifest")
  api -L "https://$REGISTRY/v2/$1/blobs/$config" | jq -r '.created'
}

delete() {
  api -X DELETE -o /dev/null -w '%{http_code}\n' "https://$REGISTRY/v2/$1/manifests/$2"
}

cmd="${1:?usage: $0 repos|tags|digest|created|delete ...}"; shift
"$cmd" "$@"
