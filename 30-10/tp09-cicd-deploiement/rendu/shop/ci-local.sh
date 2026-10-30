#!/usr/bin/env bash
# ci-local.sh — rejoue en local les étapes de .github/workflows/ci.yml, contre le registre du TP03.
#
#   EVENT=pr   ./ci-local.sh          lint + build de l'étape test + build des images (sans push)
#   EVENT=main ./ci-local.sh          + push sha-<sha>, gate (trivy bloquant), signature, déploiement préprod
#   EVENT=tag REF=v1.2.0 ./ci-local.sh  + tags semver, vérification de signature, déploiement prod (confirmation)
#
# Variables : REGISTRY_USER / REGISTRY_PASSWORD (compte « ci » du TP03, obligatoire pour main/tag),
#   GIT_SHA (défaut : HEAD), PLATFORMS (linux/amd64,linux/arm64), REGISTRY (localhost:5000),
#   DEPLOY_REGISTRY (registry.local:5000 : nom du même registre vu depuis le serveur).
# Différences avec GitHub Actions : cache registre au lieu de type=gha, signature cosign par clé (TP03)
# au lieu de keyless OIDC (pas d'émetteur OIDC hors CI), approbation prod = confirmation interactive.
set -euo pipefail
cd "$(dirname "$0")"
SHOP="$PWD"
EVENT="${EVENT:-pr}"
REF="${REF:-}"
REGISTRY="${REGISTRY:-localhost:5000}"
DEPLOY_REGISTRY="${DEPLOY_REGISTRY:-registry.local:5000}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short=7 HEAD)}"
TP03="${TP03:-$SHOP/../../../../26-10/tp03-registry-supply-chain/rendu}"
REGISTRY_CA="${REGISTRY_CA:-$TP03/registry/certs/ca.crt}"
COSIGN_KEY="${COSIGN_KEY:-$TP03/supply-chain/cosign.key}"
CI="$SHOP/.ci"
SERVICES=(api worker)
declare -A CONTEXT=([api]=apps/shopapi [worker]=apps/shop-worker)
declare -A IMAGE=([api]=shopapi [worker]=shop-worker)

step() { printf '\n\e[1;34m▶ %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32m✔\e[0m %s\n' "$*"; }
die()  { printf '  \e[31m✘ %s\e[0m\n' "$*"; exit 1; }
SECONDS=0

# ---- Configuration Docker isolée : identifiants du registre sans credential helper ----------------
mkdir -p "$CI/docker"
CTX="${DOCKER_CONTEXT:-$(docker context show)}"   # contexte courant, lu AVANT de changer DOCKER_CONFIG
export DOCKER_CONFIG="$CI/docker"
for d in cli-plugins contexts buildx; do [[ -e $DOCKER_CONFIG/$d ]] || ln -s "$HOME/.docker/$d" "$DOCKER_CONFIG/$d"; done
if [[ $EVENT != pr ]]; then
  : "${REGISTRY_USER:=ci}"; : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD requis (compte ci du registre TP03)}"
  auth=$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASSWORD" | base64 -w0)
  jq -n --arg a "$auth" --arg r1 "$REGISTRY" --arg r2 "$DEPLOY_REGISTRY" --arg ctx "$CTX" \
    '{auths: {($r1): {auth: $a}, ($r2): {auth: $a}}, currentContext: $ctx}' > "$DOCKER_CONFIG/config.json"
else
  jq -n --arg ctx "$CTX" '{auths: {}, currentContext: $ctx}' > "$DOCKER_CONFIG/config.json"
fi
chmod 600 "$DOCKER_CONFIG/config.json"
# pip.conf : en CI, vient d'un secret (PIP_CONF) ; ici l'exemple public
[[ -f apps/shop-worker/pip.conf ]] || cp apps/shop-worker/pip.conf.example apps/shop-worker/pip.conf

# ---- Builder BuildKit qui fait confiance à la CA du registre ----------------------------------------
BUILDER=shop-ci
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  # http = false explicite : sinon BuildKit parle en HTTP clair à tout registre « localhost »
  printf '[registry."%s"]\n  http = false\n  ca = ["%s"]\n' "$REGISTRY" "$REGISTRY_CA" > "$CI/buildkitd.toml"
  docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host \
    --buildkitd-config "$CI/buildkitd.toml" --bootstrap >/dev/null
fi

# ---- Tags et labels (équivalent docker/metadata-action) ---------------------------------------------
VERSION_LABEL="sha-$GIT_SHA"
TAGS=("sha-$GIT_SHA")
if [[ $EVENT == tag ]]; then
  [[ $REF =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "REF doit être un tag semver vX.Y.Z (reçu : '$REF')"
  VERSION_LABEL="${REF#v}"
  TAGS+=("${REF#v}" "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}")
fi
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LABELS=()
for l in "version=$VERSION_LABEL" "revision=$GIT_SHA" "created=$CREATED" \
         "source=https://github.com/shop-sas/shop" "vendor=Shop SAS"; do
  LABELS+=(--label "org.opencontainers.image.$l")
done
echo "événement=$EVENT ref=${REF:-–} sha=$GIT_SHA tags=${TAGS[*]} plateformes=$PLATFORMS"

# ================================ lint ================================================================
step "lint : hadolint + docker compose config"
for s in "${SERVICES[@]}"; do
  docker run --rm -i -v "$SHOP/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.12.0 \
    hadolint --config /.config/hadolint.yaml - < "${CONTEXT[$s]}/Dockerfile" && ok "hadolint ${CONTEXT[$s]}/Dockerfile"
done
docker compose --env-file .env.example config -q && ok "compose (dev) valide"
REGISTRY=$DEPLOY_REGISTRY VERSION=sha-$GIT_SHA docker compose --env-file .env.example \
  -f compose.yml -f compose.prod.yml config -q && ok "compose (prod) valide"

# ================================ test ================================================================
step "test : build de l'étape test (lint + tests unitaires dans le Dockerfile)"
for s in "${SERVICES[@]}"; do
  secret=(); [[ $s == worker ]] && secret=(--secret id=pipconf,src=apps/shop-worker/pip.conf)
  docker buildx build --builder "$BUILDER" -q --target test "${secret[@]}" --output type=cacheonly \
    --cache-from "type=registry,ref=$REGISTRY/cache:$s" "${CONTEXT[$s]}" >/dev/null && ok "tests $s"
done

# ================================ build (matrice api/worker) =========================================
build() {   # build <service> <push:true|false>
  local s=$1 push=$2 out tags=() secret=() cache_to=()
  for t in "${TAGS[@]}"; do tags+=(-t "$REGISTRY/${IMAGE[$s]}:$t"); done
  [[ $s == worker ]] && secret=(--secret id=pipconf,src=apps/shop-worker/pip.conf)
  [[ $push == true ]] && cache_to=(--cache-to "type=registry,ref=$REGISTRY/cache:$s,mode=max")
  if [[ $push == true ]]; then out=(--push); else out=(--output type=cacheonly); fi
  docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" "${tags[@]}" "${LABELS[@]}" \
    --build-arg "APP_VERSION=$VERSION_LABEL" --build-arg "VERSION=$VERSION_LABEL" --build-arg "GIT_SHA=$GIT_SHA" \
    "${secret[@]}" --provenance=mode=max --sbom=true \
    --cache-from "type=registry,ref=$REGISTRY/cache:$s" "${cache_to[@]}" \
    --metadata-file "$CI/meta-$s.json" "${out[@]}" "${CONTEXT[$s]}" 2> "$CI/build-$s.log" \
    || { tail -20 "$CI/build-$s.log"; die "build $s"; }
}
if [[ $EVENT == pr ]]; then
  step "build des images multi-arch (sans push)"
  for s in "${SERVICES[@]}"; do build "$s" false; ok "${IMAGE[$s]} construit ($PLATFORMS)"; done
  printf '\n\e[32mPR verte\e[0m en %ss\n' "$SECONDS"; exit 0
fi

step "build + push multi-arch, provenance + SBOM"
declare -A DIGEST
for s in "${SERVICES[@]}"; do
  build "$s" true
  DIGEST[$s]=$(jq -r '."containerimage.digest"' "$CI/meta-$s.json")
  ok "$REGISTRY/${IMAGE[$s]}:{$(IFS=,; echo "${TAGS[*]}")} @ ${DIGEST[$s]:0:19}…"
done

# ================================ gate : scan bloquant + politique (TP03) ============================
step "release gate (labels OCI, non-root, HEALTHCHECK, trivy HIGH/CRITICAL corrigeables, secrets)"
for s in "${SERVICES[@]}"; do
  ref="$REGISTRY/${IMAGE[$s]}@${DIGEST[$s]}"
  docker pull -q --platform linux/amd64 "$ref" >/dev/null
  REGISTRY_CA="$REGISTRY_CA" COSIGN_KEY="$COSIGN_KEY" ./release-gate.sh "$ref" > "$CI/gate-$s.log" 2>&1 \
    && ok "gate ${IMAGE[$s]} : ACCEPTÉ" || { sed 's/^/    /' "$CI/gate-$s.log"; die "gate ${IMAGE[$s]} : REFUSÉ (pipeline arrêté, rien n'est déployé)"; }
done

# ================================ signature ==========================================================
cosign() {
  docker run --rm --network host -e COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" \
    -e DOCKER_CONFIG=/cfg -v "$DOCKER_CONFIG/config.json:/cfg/config.json:ro" \
    -e SSL_CERT_FILE=/ca.crt -v "$REGISTRY_CA:/ca.crt:ro" \
    -v "$(dirname "$COSIGN_KEY"):/keys:ro" ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"
}
step "signature cosign (par digest)"
for s in "${SERVICES[@]}"; do
  cosign sign --yes --key "/keys/$(basename "$COSIGN_KEY")" --tlog-upload=false \
    -a "git_sha=$GIT_SHA" -a "ci=ci-local" "$REGISTRY/${IMAGE[$s]}@${DIGEST[$s]}" >/dev/null 2>&1 \
    && ok "signé ${IMAGE[$s]}@${DIGEST[$s]:0:19}…"
done

# ================================ déploiement ========================================================
verify() {   # côté déploiement : on ne déploie qu'un digest signé par la CI
  local s
  for s in "${SERVICES[@]}"; do
    cosign verify --key "/keys/$(basename "${COSIGN_KEY%.key}").pub" --insecure-ignore-tlog=true \
      -a "git_sha=$GIT_SHA" "$REGISTRY/${IMAGE[$s]}@${DIGEST[$s]}" >/dev/null 2>&1 \
      && ok "signature vérifiée : ${IMAGE[$s]}@${DIGEST[$s]:0:19}… (git_sha=$GIT_SHA)" \
      || die "signature invalide pour ${IMAGE[$s]} : déploiement refusé"
  done
}
deploy() {   # deploy <contexte> <tag>
  step "déploiement $1 (VERSION=$2)"
  verify
  export PATH="$CI/bin:$PATH"
  DOCKER_CONTEXT="$1" REGISTRY="$DEPLOY_REGISTRY" VERSION="$2" ./deploy/rolling-update.sh
}
if [[ $EVENT == main ]]; then
  deploy preprod "sha-$GIT_SHA"
elif [[ $EVENT == tag ]]; then
  # équivalent de « environment: production » avec reviewers obligatoires
  read -r -p "Approbation manuelle : déployer ${REF} en PROD ? [y/N] " answer
  [[ $answer == y ]] || die "déploiement prod non approuvé"
  deploy "${PROD_CONTEXT:-preprod}" "${REF#v}"
fi
printf '\n\e[32mpipeline vert\e[0m (%s) en %ss\n' "$EVENT" "$SECONDS"
