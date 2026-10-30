# syntax=docker/dockerfile:1.7
# GestStock — PHP 7.3 (Debian 10, installé à la main) → php:8.3-apache, non-root, logs sur stdout/stderr.
# Une seule image pour l'application web et le rapport planifié (service cron : supercronic).
ARG PHP_IMAGE=php:8.3.36-apache-bookworm

# ---- supercronic : binaire officiel vérifié par somme de contrôle, une étape par architecture
FROM scratch AS supercronic-amd64
ADD --chmod=755 --checksum=sha256:cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123 \
    https://github.com/aptible/supercronic/releases/download/v0.2.51/supercronic-linux-amd64 /supercronic
FROM scratch AS supercronic-arm64
ADD --chmod=755 --checksum=sha256:4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94 \
    https://github.com/aptible/supercronic/releases/download/v0.2.51/supercronic-linux-arm64 /supercronic
# hadolint ignore=DL3006
FROM supercronic-${TARGETARCH} AS supercronic

# ---- ext : compilation de pdo_mysql (la chaîne de compilation ne sert qu'ici)
FROM ${PHP_IMAGE} AS ext
RUN docker-php-ext-install -j"$(nproc)" pdo_mysql \
 && cp "$(php-config --extension-dir)/pdo_mysql.so" /pdo_mysql.so

# ---- base : runtime commun (Apache + PHP de prod + msmtp + supercronic)
FROM ${PHP_IMAGE} AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# msmtp remplace le postfix local du legacy : mail() → relais SMTP_HOST
RUN apt-get update \
 && apt-get install -y --no-install-recommends msmtp=1.8.23-1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=ext /pdo_mysql.so /tmp/pdo_mysql.so
RUN mv /tmp/pdo_mysql.so "$(php-config --extension-dir)/" \
 && docker-php-ext-enable pdo_mysql \
 && cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini \
 # Apache sur 8080 (non-root), sans le site par défaut, avec l'IP réelle du client derrière Traefik
 && sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf \
 && a2dissite -q 000-default && a2enmod -q remoteip \
 # répertoires écrits à l'exécution par www-data (pid, verrous, photos)
 && install -d -o www-data -g www-data -m 755 /var/www/uploads \
 && chown -R www-data:www-data /var/run/apache2 /var/lock/apache2 \
 && rm -rf /var/www/html
COPY --from=supercronic /supercronic /usr/local/bin/supercronic
COPY docker/php-prod.ini /usr/local/etc/php/conf.d/zz-geststock.ini
COPY docker/apache-geststock.conf /etc/apache2/sites-enabled/geststock.conf
ENV TZ=Europe/Paris \
    UPLOAD_DIR=/var/www/uploads \
    LOG_FILE=php://stderr \
    SMTP_HOST=mailpit \
    SMTP_PORT=1025 \
    SMTP_FROM=geststock@shop.example
WORKDIR /var/www/geststock

# ---- test : php -l sur tout le code + configuration Apache valide (l'image finale en dépend)
FROM base AS test
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY app ./
RUN find . -name '*.php' -print0 | xargs -0 -n1 php -l \
 && apache2ctl -t \
 && php -m | grep -qx pdo_mysql \
 && touch /usr/local/share/geststock-tests-ok

# ---- runtime
FROM base AS runtime
COPY --from=test /usr/local/share/geststock-tests-ok /usr/local/share/geststock-tests-ok
# code en root:root, lisible mais non modifiable par www-data
COPY app ./
ARG VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="geststock" \
      org.opencontainers.image.description="GestStock — gestion d'inventaire (PHP 8.3, Apache)" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/shop-sas/geststock-docker" \
      org.opencontainers.image.base.name="docker.io/library/php:8.3.36-apache-bookworm"
ENV APP_VERSION=${VERSION}
USER www-data
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["sh", "-c", "curl -fsS --max-time 2 'http://127.0.0.1:8080/?health' | grep -qx OK"]
# STOPSIGNAL SIGWINCH hérité de l'image officielle : arrêt « graceful » d'Apache (requêtes en cours terminées)
CMD ["apache2-foreground"]
