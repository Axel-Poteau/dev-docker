#!/usr/bin/env bash
# experiences.sh — une expérience par mesure de durcissement, sur des conteneurs jetables.
#   ./experiences.sh > experiences.txt
set -uo pipefail
ALPINE=alpine:3.20
DEBIAN=debian:12.7-slim
PYTHON=python:3.12-alpine

for img in $ALPINE $DEBIAN $PYTHON; do docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null; done

x() { echo "\$ $*"; eval "$@" 2>&1 | sed 's/^/  /'; echo "  (rc=${PIPESTATUS[0]})"; }
title() { printf '\n### %s\n' "$1"; }

title "1. --read-only"
x "docker run --rm --read-only $ALPINE touch /x"
x "docker run --rm --read-only --tmpfs /tmp $ALPINE sh -c 'touch /tmp/x && ls -l /tmp/x && mount | grep \" /tmp \"'"

title "2. --cap-drop ALL"
x "docker run --rm $ALPINE sh -c 'grep CapEff /proc/self/status'"
x "docker run --rm --cap-drop ALL $ALPINE sh -c 'grep CapEff /proc/self/status'"
# ping : Docker pose net.ipv4.ping_group_range=0 2147483647 → sockets ICMP « datagram » sans NET_RAW
GW=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
x "docker run --rm --cap-drop ALL $ALPINE sh -c 'sysctl net.ipv4.ping_group_range; ping -c1 -W2 $GW'"
x "docker run --rm --cap-drop ALL --sysctl net.ipv4.ping_group_range='1 0' $ALPINE ping -c1 -W2 $GW"
x "docker run --rm --cap-drop ALL --cap-add NET_RAW --sysctl net.ipv4.ping_group_range='1 0' $ALPINE ping -c1 -W2 $GW"
# ports < 1024 : Docker pose aussi net.ipv4.ip_unprivileged_port_start=0 → NET_BIND_SERVICE inutile
x "docker run --rm --cap-drop ALL $ALPINE sh -c 'sysctl net.ipv4.ip_unprivileged_port_start; nc -l -p 80 & sleep 1; netstat -ltn | grep :80'"
x "docker run --rm --cap-drop ALL $ALPINE chown nobody /etc/hosts"
x "docker run --rm --cap-drop ALL --cap-add CHOWN $ALPINE sh -c 'touch /f && chown nobody /f && ls -l /f'"
# apk : root reste propriétaire des fichiers qu'il écrit → pas besoin de DAC_OVERRIDE
x "docker run --rm --cap-drop ALL $ALPINE sh -c 'apk add -q --no-cache curl && curl --version | head -1'"
# DAC_OVERRIDE : sans elle, « root » ne passe plus outre les droits d'un répertoire qui ne lui appartient pas
# (cas de l'entrypoint postgres qui écrit dans PGDATA appartenant à postgres:700)
x "docker run --rm --cap-drop ALL --cap-add CHOWN $ALPINE sh -c 'mkdir -m 700 /d && chown nobody /d && touch /d/f'"
x "docker run --rm --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE $ALPINE sh -c 'mkdir -m 700 /d && chown nobody /d && touch /d/f && echo écriture OK'"

title "3. --security-opt no-new-privileges"
x "docker run --rm $DEBIAN ls -l /usr/bin/passwd /usr/bin/su"
# copie setuid root de « id », exécutée par nobody
SETUID="cp /usr/bin/id /usr/local/bin/suid-id && chmod u+s /usr/local/bin/suid-id && setpriv --reuid 65534 --regid 65534 --clear-groups /usr/local/bin/suid-id"
x "docker run --rm $DEBIAN sh -c '$SETUID'"
x "docker run --rm --security-opt no-new-privileges $DEBIAN sh -c '$SETUID'"
x "docker run --rm --security-opt no-new-privileges $DEBIAN grep NoNewPrivs /proc/self/status"

title "4. --pids-limit 50"
x "docker run --rm --pids-limit 50 $ALPINE sh -c 'for i in \$(seq 100); do sleep 60 & done; sleep 1; ps | wc -l'"
x "docker run --rm $ALPINE sh -c 'for i in \$(seq 100); do sleep 60 & done; sleep 1; ps | wc -l'"

title "5. --memory 32m"
docker rm -f oom-test >/dev/null 2>&1
x "docker run --name oom-test --memory 32m --memory-swap 32m $PYTHON python -c \"x='a'*100_000_000\""
x "docker inspect oom-test --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}'"
docker rm -f oom-test >/dev/null 2>&1
x "docker run --rm --memory 128m $PYTHON python -c \"x='a'*100_000_000; print(len(x))\""

title "6. --user 1000"
x "docker run --rm --user 1000 $ALPINE id"
docker volume rm -f exp-data >/dev/null 2>&1
x "docker run --rm -v exp-data:/data $ALPINE sh -c 'echo root > /data/f && ls -ln /data'"
x "docker run --rm --user 1000 -v exp-data:/data $ALPINE sh -c 'echo app >> /data/f'"
x "docker run --rm -v exp-data:/data $ALPINE chown -R 1000:1000 /data"
x "docker run --rm --user 1000 -v exp-data:/data $ALPINE sh -c 'echo app >> /data/f && cat /data/f'"
docker volume rm -f exp-data >/dev/null 2>&1

title "7. seccomp"
x "docker run --rm $ALPINE unshare --user id"
x "docker run --rm --security-opt seccomp=unconfined $ALPINE unshare --user id"
x "docker run --rm $ALPINE grep Seccomp /proc/self/status"
x "docker run --rm --security-opt seccomp=unconfined $ALPINE grep Seccomp /proc/self/status"
profile=$(mktemp); trap 'rm -f "$profile"' EXIT
curl -fsSL https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json -o "$profile"
syscalls=$(sed -n 's/^#define __NR_\([a-z0-9_]*\) .*/\1/p' /usr/include/x86_64-linux-gnu/asm/unistd_64.h | sort -u)
total=$(wc -l <<<"$syscalls")
# autorisés sans condition (ni capacité, ni architecture, ni filtre d'argument)
always=$(jq -r '.syscalls[] | select(.action=="SCMP_ACT_ALLOW" and (.includes // {})=={} and (.excludes // {})=={} and ((.args // [])|length)==0) | .names[]' "$profile" | sort -u)
blocked=$(comm -23 <(echo "$syscalls") <(echo "$always"))
echo "profil par défaut : defaultAction=$(jq -r .defaultAction "$profile") (EPERM pour tout ce qui n'est pas listé)"
echo "  appels système x86_64 du noyau             : $total"
echo "  autorisés sans condition                   : $(comm -12 <(echo "$syscalls") <(echo "$always") | wc -l)"
echo "  non autorisés sans condition               : $(wc -l <<<"$blocked")  (dont certains rouverts par une capacité ou un filtre d'argument)"
echo "  exemples : $(grep -xE 'bpf|mount|umount2|unshare|setns|ptrace|kexec_load|init_module|reboot|swapon|keyctl|add_key|clock_settime|open_by_handle_at|userfaultfd|perf_event_open' <<<"$blocked" | paste -sd, -)"
