#!/usr/bin/env bash
# audit.sh [FILTRE docker ps]... — audit de durcissement des conteneurs en cours d'exécution.
#   ./audit.sh                                          tous les conteneurs
#   ./audit.sh --filter label=com.docker.compose.project=shop
#
# Contrôles par conteneur (un écart = une ligne ✘) :
#   user    utilisateur non-root (USER de l'image ou --user)
#   priv    pas --privileged
#   caps    CapDrop contient ALL ; CapAdd affiché (doit être justifié)
#   rootfs  système de fichiers racine en lecture seule
#   mem     limite mémoire définie
#   pids    PidsLimit défini (> 0)
#   nnp     security_opt no-new-privileges
#   sock    /var/run/docker.sock non monté
#
# Exception documentée : label "audit.allow=<contrôle>,<contrôle>" sur le conteneur (ex. le proxy de
# socket monte forcément la socket). L'exception est affichée en ~ et ne compte pas comme écart.
# Code retour : 0 si aucun écart, 1 sinon.
set -euo pipefail

mapfile -t ids < <(docker ps -q "$@")
(( ${#ids[@]} )) || { echo "aucun conteneur"; exit 0; }

red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' bold=$'\e[1m' reset=$'\e[0m'
total=0

# Une ligne par conteneur, champs séparés par « | » (un séparateur blanc fusionnerait les champs vides)
fmt='{{.Name}}|{{.Config.User}}|{{.HostConfig.Privileged}}|{{join .HostConfig.CapDrop ","}}|{{join .HostConfig.CapAdd ","}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Memory}}|{{if .HostConfig.PidsLimit}}{{.HostConfig.PidsLimit}}{{else}}0{{end}}|{{join .HostConfig.SecurityOpt ","}}|{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}|{{index .Config.Labels "audit.allow"}}'

while IFS='|' read -r name user priv capdrop capadd ro mem pids secopt mounts allow; do
  name=${name#/}
  issues=0
  printf '%s%s%s\n' "$bold" "$name" "$reset"
  check() {   # check <contrôle> <ok:0|1> <message>
    if [[ $2 == 0 ]]; then printf '  %s✔%s %-6s %s\n' "$green" "$reset" "$1" "$3"
    elif [[ ",$allow," == *",$1,"* ]]; then printf '  %s~%s %-6s %s (exception audit.allow)\n' "$yellow" "$reset" "$1" "$3"
    else printf '  %s✘%s %-6s %s\n' "$red" "$reset" "$1" "$3"; issues=$((issues + 1)); fi
  }
  case "${user%%:*}" in ""|root|0) check user 1 "root (USER='$user')" ;; *) check user 0 "$user" ;; esac
  [[ $priv == false ]] && check priv 0 "non privilégié" || check priv 1 "--privileged"
  [[ ",$capdrop," == *",ALL,"* ]] && check caps 0 "drop ALL, add [${capadd}]" \
    || check caps 1 "capabilités par défaut conservées (drop [${capdrop}], add [${capadd}])"
  [[ $ro == true ]] && check rootfs 0 "read-only" || check rootfs 1 "rootfs inscriptible"
  (( mem > 0 )) && check mem 0 "$((mem / 1024 / 1024)) Mo" || check mem 1 "aucune limite mémoire"
  (( pids > 0 )) && check pids 0 "$pids" || check pids 1 "aucune limite de PID"
  [[ $secopt == *no-new-privileges* ]] && check nnp 0 "no-new-privileges" || check nnp 1 "no-new-privileges absent"
  [[ $mounts == *docker.sock* ]] && check sock 1 "socket Docker montée" || check sock 0 "pas de socket Docker"
  total=$((total + issues))
done < <(docker inspect --format "$fmt" "${ids[@]}" | sort)

echo
if (( total > 0 )); then printf '%s%d écart(s)%s sur %d conteneur(s)\n' "$red" "$total" "$reset" "${#ids[@]}"; exit 1; fi
printf '%saucun écart%s sur %d conteneur(s)\n' "$green" "$reset" "${#ids[@]}"
