#!/usr/bin/env bash
# retention.sh REPO [N] [--dry-run]
# Garde les N tags hors semver les plus récents (date .created de l'image) ; les tags semver (1.2.3, v1.2.3)
# ne sont jamais supprimés. Un manifeste partagé avec un tag conservé n'est pas supprimé (supprimer un
# manifeste supprime TOUS les tags qui pointent dessus).
# Après suppression : lancer le garbage-collect pour libérer les blobs.
set -euo pipefail
cd "$(dirname "$0")"
REPO="${1:?usage: retention.sh REPO [N] [--dry-run]}"
KEEP="${2:-5}"
DRY_RUN=false; [[ "${3:-}" == "--dry-run" ]] && DRY_RUN=true
SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

declare -A DIGEST
candidates=()
protected_digests=()
for tag in $(./registry-api.sh tags "$REPO"); do
  DIGEST[$tag]=$(./registry-api.sh digest "$REPO" "$tag")
  if [[ $tag =~ $SEMVER ]]; then
    protected_digests+=("${DIGEST[$tag]}")
  else
    candidates+=("$(./registry-api.sh created "$REPO" "$tag") $tag")
  fi
done

mapfile -t sorted < <(printf '%s\n' "${candidates[@]}" | sort -r)
i=0
for line in "${sorted[@]}"; do
  tag=${line#* }
  if (( i < KEEP )); then
    echo "garde     $tag (${line%% *})"
    protected_digests+=("${DIGEST[$tag]}")
  else
    to_delete+=("$tag")
  fi
  i=$((i + 1))
done

for tag in "${to_delete[@]:-}"; do
  [[ -z "$tag" ]] && continue
  d=${DIGEST[$tag]}
  if printf '%s\n' "${protected_digests[@]}" | grep -qx "$d"; then
    echo "conserve  $tag (manifeste partagé avec un tag gardé : $d)"
  elif $DRY_RUN; then
    echo "[dry-run] supprimerait $tag ($d)"
  else
    echo "supprime  $tag ($d) -> HTTP $(./registry-api.sh delete "$REPO" "$d")"
  fi
done
