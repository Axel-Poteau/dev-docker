#!/bin/sh
# sshd en arrière-plan, puis dockerd (PID 1 via l'entrypoint officiel DinD)
set -e
ssh-keygen -A >/dev/null
install -d -o deploy -g docker -m 700 /home/deploy/.ssh
[ -f /keys/authorized_keys ] && install -o deploy -g docker -m 600 /keys/authorized_keys /home/deploy/.ssh/authorized_keys
# confiance dans la CA du registre privé (TP03)
[ -f /keys/registry-ca.crt ] && install -D -m 644 /keys/registry-ca.crt "/etc/docker/certs.d/registry.local:5000/ca.crt"
/usr/sbin/sshd -e
exec dockerd-entrypoint.sh dockerd --group docker
