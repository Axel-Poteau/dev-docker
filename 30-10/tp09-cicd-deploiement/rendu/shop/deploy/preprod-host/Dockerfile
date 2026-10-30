# Hôte « distant » de TP : un daemon Docker (DinD) joignable en SSH par l'utilisateur deploy.
# Remplace une VM de préprod ; en vrai : Debian + docker-ce + openssh, provisionnés par Ansible.
FROM docker:28.4.0-dind
RUN apk add --no-cache openssh-server \
 && addgroup -S docker 2>/dev/null; adduser -D -s /bin/sh -G docker deploy \
 && passwd -u deploy 2>/dev/null; \
    sed -i -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
           -e 's/^#\?PermitRootLogin .*/PermitRootLogin no/' \
           -e 's/^AllowTcpForwarding .*/AllowTcpForwarding no/' /etc/ssh/sshd_config \
 && echo 'AllowUsers deploy' >> /etc/ssh/sshd_config \
 && install -d -o deploy -g docker -m 750 /srv/shop
COPY entrypoint.sh /usr/local/bin/preprod-entrypoint.sh
EXPOSE 22 80
ENTRYPOINT ["/usr/local/bin/preprod-entrypoint.sh"]
