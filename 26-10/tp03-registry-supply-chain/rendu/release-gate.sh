#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE]
# Objectif : refuser la publication d'une image qui ne respecte pas la politique Shop SAS.
#
# Contrôles (tous exécutés, le rapport liste chaque échec) :
#   1. labels OCI org.opencontainers.image.{version,revision,source} présents et non vides
#   2. utilisateur non-root
#   3. HEALTHCHECK défini
#   4. aucune CVE HIGH/CRITICAL disposant d'un correctif (trivy --ignore-unfixed)
#   5. aucun secret détecté (trivy --scanners secret)
# Si tout passe et --push est donné : push, signature cosign (par digest), SBOM syft attesté.
#
# Outils lancés en conteneur (rien à installer). Variables :
#   COSIGN_KEY (supply-chain/cosign.key), COSIGN_PASSWORD (vide), REGISTRY_CA (registry/certs/ca.crt),
#   DOCKER_CONFIG (identifiants du registre, cf. docker login), TRIVY_SEVERITY (HIGH,CRITICAL)
set -euo pipefail

usage() { echo "usage: $0 IMAGE [--push REGISTRY_IMAGE]" >&2; exit 2; }
IMAGE="${1:-}"; [[ -z "$IMAGE" ]] && usage
PUSH_TO=""
if [[ "${2:-}" == "--push" ]]; then PUSH_TO="${3:-}"; [[ -z "$PUSH_TO" ]] && usage; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
COSIGN_KEY="${COSIGN_KEY:-$HERE/supply-chain/cosign.key}"
REGISTRY_CA="${REGISTRY_CA:-$HERE/registry/certs/ca.crt}"
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
TRIVY_SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
SOCK=/var/run/docker.sock

trivy()  { docker run --rm -v "$SOCK:$SOCK" -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.57.1 "$@"; }
syft()   { docker run --rm -v "$SOCK:$SOCK" anchore/syft:v1.18.1 "$@"; }
cosign() {
  docker run --rm --network host -e COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" \
    -e DOCKER_CONFIG=/cfg -v "$DOCKER_CONFIG/config.json:/cfg/config.json:ro" \
    -e SSL_CERT_FILE=/ca.crt -v "$REGISTRY_CA:/ca.crt:ro" \
    -v "$(dirname "$COSIGN_KEY"):/keys:ro" -v "$WORK:/work" -w /work \
    ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"
}

FAILURES=0
ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; }
ko()   { printf '  \e[31m✘\e[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
step() { printf '\n\e[1m== %s\e[0m\n' "$1"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image introuvable : $IMAGE" >&2; exit 2; }
inspect() { docker image inspect "$IMAGE" --format "$1"; }

step "1. Labels OCI"
for label in version revision source; do
  value=$(inspect "{{index .Config.Labels \"org.opencontainers.image.$label\"}}")
  if [[ -n "$value" && "$value" != "<no value>" ]]; then ok "org.opencontainers.image.$label=$value"
  else ko "label org.opencontainers.image.$label absent"; fi
done

step "2. Utilisateur non-root"
user=$(inspect '{{.Config.User}}')
case "${user%%:*}" in
  ""|root|0) ko "conteneur exécuté en root (USER='${user}')" ;;
  *)         ok "USER=$user" ;;
esac

step "3. HEALTHCHECK"
hc=$(inspect '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}')
if [[ -n "$hc" && "$hc" != '["NONE"]' ]]; then ok "HEALTHCHECK ${hc:0:70}"; else ko "aucun HEALTHCHECK"; fi

step "4. Vulnérabilités $TRIVY_SEVERITY corrigeables"
if out=$(trivy image --quiet --scanners vuln --severity "$TRIVY_SEVERITY" --ignore-unfixed --exit-code 1 "$IMAGE" 2>&1); then
  ok "aucune CVE $TRIVY_SEVERITY avec correctif disponible"
else
  ko "CVE $TRIVY_SEVERITY corrigeables détectées :"
  grep -E '^Total' <<<"$out" | sed 's/^/      /'
fi

step "5. Secrets"
if out=$(trivy image --quiet --scanners secret --exit-code 1 "$IMAGE" 2>&1); then
  ok "aucun secret détecté"
else
  ko "secret(s) détecté(s) :"
  grep -E '^(CRITICAL|HIGH|MEDIUM|LOW):| /.*:[0-9]+ ' <<<"$out" | sed 's/^/      /'
fi

echo
if (( FAILURES > 0 )); then
  printf '\e[31mREFUSÉ\e[0m : %d contrôle(s) en échec pour %s\n' "$FAILURES" "$IMAGE"
  exit 1
fi
printf '\e[32mACCEPTÉ\e[0m : %s respecte la politique Shop SAS\n' "$IMAGE"

[[ -z "$PUSH_TO" ]] && exit 0

WORK=$(mktemp -d "$HERE/.gate.XXXXXX"); trap 'rm -rf "$WORK"' EXIT

step "Publication"
docker tag "$IMAGE" "$PUSH_TO"
digest=$(docker push "$PUSH_TO" | awk '/digest: sha256:/ {print $3}' | tail -1)
[[ -n "$digest" ]] || { echo "push échoué" >&2; exit 1; }
ref="${PUSH_TO%:*}@$digest"
ok "poussé : $ref"

step "Signature et SBOM (référence par digest, jamais par tag)"
syft -q "$IMAGE" -o spdx-json > "$WORK/sbom.json"
ok "SBOM : $(jq '.packages | length' "$WORK/sbom.json") paquets"
cosign sign --yes --key /keys/"$(basename "$COSIGN_KEY")" --tlog-upload=false "$ref" >/dev/null 2>&1
ok "signé : $ref"
cosign attest --yes --key /keys/"$(basename "$COSIGN_KEY")" --type spdxjson --predicate sbom.json \
  --tlog-upload=false "$ref" >/dev/null 2>&1
ok "SBOM attesté (spdxjson)"
cosign verify --key /keys/"$(basename "${COSIGN_KEY%.key}").pub" --insecure-ignore-tlog=true "$ref" >/dev/null 2>&1 \
  && ok "vérification cosign OK"
echo "$ref"
