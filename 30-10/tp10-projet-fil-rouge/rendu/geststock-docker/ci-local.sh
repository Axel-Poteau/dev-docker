#!/usr/bin/env bash
# ci-local.sh — pipeline GestStock rejoué en local (mêmes étapes que .github/workflows/ci.yml).
#   EVENT=pr   ./ci-local.sh   lint → test (php -l, apachectl -t) → build → intégration (stack éphémère)
#   EVENT=main ./ci-local.sh   + release gate (trivy, SBOM) → push sha-<sha> → signature → rolling update
# Variables : REGISTRY_PASSWORD (compte « ci » du registre TP03, pour main), GIT_SHA (défaut HEAD),
#   DEPLOY_COMPOSE_FILE (fichiers compose de l'environnement cible).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"; CI="$ROOT/.ci"
EVENT="${EVENT:-pr}"
REGISTRY="${REGISTRY:-localhost:5000}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short=7 HEAD)}"
VERSION="sha-$GIT_SHA"; IMAGE="$REGISTRY/geststock:$VERSION"
TP03="${TP03:-$ROOT/../../../../26-10/tp03-registry-supply-chain/rendu}"
REGISTRY_CA="${REGISTRY_CA:-$TP03/registry/certs/ca.crt}"; COSIGN_KEY="${COSIGN_KEY:-$TP03/supply-chain/cosign.key}"
DEPLOY_COMPOSE_FILE="${DEPLOY_COMPOSE_FILE:-compose.yml:compose.prod.yml:compose.hardened.yml}"
DEPLOY_SMTP_HOST="${SMTP_HOST:-}"              # relais SMTP de l'environnement cible (lu avant l'intégration)
step() { printf '\n\e[1;34m▶ %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32m✔\e[0m %s\n' "$*"; }
die()  { printf '  \e[31m✘ %s\e[0m\n' "$*"; exit 1; }
SECONDS=0
mkdir -p "$CI"
unset COMPOSE_FILE COMPOSE_PROJECT_NAME        # pas de fuite de l'environnement du développeur
echo "événement=$EVENT sha=$GIT_SHA image=$IMAGE"

# ================================ lint ===============================================================
step "lint"
docker run --rm -i hadolint/hadolint:v2.14.0 hadolint --failure-threshold warning - < Dockerfile && ok "hadolint Dockerfile"
docker run --rm -v "$ROOT:/src:ro" -w /src koalaman/shellcheck:v0.10.0 -S warning -x ci-local.sh scripts/*.sh deploy/*.sh \
  legacy-sample/*.sh && ok "shellcheck (scripts d'exploitation)"
for files in compose.yml:compose.override.yml:compose.mailpit.yml compose.yml:compose.prod.yml:compose.hardened.yml \
             compose.yml:compose.prod.yml:compose.hardened.yml:compose.observability.yml; do
  COMPOSE_FILE=$files REGISTRY=$REGISTRY VERSION=$VERSION SMTP_HOST=relay docker compose --env-file .env.example config -q \
    && ok "compose ${files//compose./} valide"
done
docker compose -f observability/compose.yml config -q && ok "observability/compose.yml valide"

# ================================ test + build =======================================================
step "test : étape test du Dockerfile (php -l sur tout le code, apachectl -t, extension pdo_mysql)"
docker buildx build -q --target test . >/dev/null && ok "tests"
step "build"
docker buildx build -q --load -t "$IMAGE" --build-arg "VERSION=$VERSION" --build-arg "GIT_SHA=$GIT_SHA" \
  --label "org.opencontainers.image.created=$(git log -1 --format=%cI)" . >/dev/null
ok "$IMAGE ($(docker image inspect "$IMAGE" --format '{{.Size}}' | numfmt --to=iec))"

# ================================ intégration : stack éphémère =======================================
step "intégration : stack prod + durcie éphémère (projet geststock-ci, port 18090)"
export COMPOSE_PROJECT_NAME=geststock-ci HTTP_PORT=18090 SECRETS_DIR="$CI/secrets" REGISTRY VERSION SMTP_HOST=mailpit
CI_FILES=compose.yml:compose.prod.yml:compose.hardened.yml:compose.mailpit.yml
mkdir -p "$SECRETS_DIR"
for s in db_password db_root_password; do openssl rand -hex 24 > "$SECRETS_DIR/$s.txt"; chmod 644 "$SECRETS_DIR/$s.txt"; done
cleanup() { COMPOSE_FILE=$CI_FILES docker compose down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup   # projet vierge : un volume db resté d'un run précédent aurait été initialisé avec d'autres secrets
COMPOSE_FILE=$CI_FILES docker compose up -d --wait >/dev/null 2>&1 || {
  COMPOSE_FILE=$CI_FILES docker compose ps; COMPOSE_FILE=$CI_FILES docker compose logs --tail 20 app db; die "stack éphémère pas healthy"; }
ok "stack healthy en ${SECONDS}s cumulées"
COMPOSE_FILE=$CI_FILES COMPOSE="docker compose" BASE_URL=http://localhost:18090 APP_HOST=geststock.localhost \
  ./scripts/smoke-test.sh | sed 's/^/  /'
./scripts/audit.sh --filter label=com.docker.compose.project=geststock-ci > "$CI/audit.txt" \
  && ok "audit.sh : $(tail -1 "$CI/audit.txt" | sed 's/\x1b\[[0-9;]*m//g')" || { cat "$CI/audit.txt"; die "audit.sh : écarts"; }
cleanup; trap - EXIT; ok "stack éphémère supprimée (down -v)"
unset COMPOSE_PROJECT_NAME HTTP_PORT SECRETS_DIR SMTP_HOST

if [[ $EVENT == pr ]]; then printf '\n\e[32mPR verte\e[0m en %ss\n' "$SECONDS"; exit 0; fi

# ================================ gate, push, signature ==============================================
step "release gate (labels OCI, non-root, HEALTHCHECK, trivy HIGH/CRITICAL corrigeables, secrets)"
REGISTRY_CA="$REGISTRY_CA" COSIGN_KEY="$COSIGN_KEY" ./scripts/release-gate.sh "$IMAGE" > "$CI/gate.log" 2>&1 \
  && ok "ACCEPTÉ" || { sed 's/^/    /' "$CI/gate.log"; die "REFUSÉ : rien n'est publié"; }

: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD requis (compte ci du registre TP03)}"
CTX=$(docker context show)
export DOCKER_CONFIG="$CI/docker"; mkdir -p "$DOCKER_CONFIG"
for d in cli-plugins contexts buildx; do [[ -e $DOCKER_CONFIG/$d ]] || ln -s "$HOME/.docker/$d" "$DOCKER_CONFIG/$d"; done
jq -n --arg a "$(printf 'ci:%s' "$REGISTRY_PASSWORD" | base64 -w0)" --arg r "$REGISTRY" --arg c "$CTX" \
  '{auths: {($r): {auth: $a}}, currentContext: $c}' > "$DOCKER_CONFIG/config.json"; chmod 600 "$DOCKER_CONFIG/config.json"
step "push + signature (par digest)"
digest=$(docker push "$IMAGE" | awk '/digest: sha256:/ {print $3}' | tail -1); [[ -n $digest ]] || die "push"
ref="$REGISTRY/geststock@$digest"; ok "poussé : $ref"
cosign() {
  docker run --rm --network host -e COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" -e DOCKER_CONFIG=/cfg \
    -v "$DOCKER_CONFIG/config.json:/cfg/config.json:ro" -e SSL_CERT_FILE=/ca.crt -v "$REGISTRY_CA:/ca.crt:ro" \
    -v "$(dirname "$COSIGN_KEY"):/keys:ro" ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"
}
cosign sign --yes --key "/keys/$(basename "$COSIGN_KEY")" --tlog-upload=false -a "git_sha=$GIT_SHA" "$ref" >/dev/null 2>&1 && ok "signé"

# ================================ déploiement ========================================================
step "déploiement (rolling update) — signature vérifiée d'abord"
cosign verify --key "/keys/$(basename "${COSIGN_KEY%.key}").pub" --insecure-ignore-tlog=true -a "git_sha=$GIT_SHA" "$ref" \
  >/dev/null 2>&1 && ok "signature vérifiée (git_sha=$GIT_SHA)" || die "signature invalide : déploiement refusé"
COMPOSE_FILE="$DEPLOY_COMPOSE_FILE" VERSION="$VERSION" SMTP_HOST="${DEPLOY_SMTP_HOST:?SMTP_HOST de la cible requis}" \
  ./deploy/rolling-update.sh
printf '\n\e[32mpipeline vert\e[0m (%s) en %ss\n' "$EVENT" "$SECONDS"
