# syntax=docker/dockerfile:1.7
# shopapi — image conforme aux standards Shop SAS (multi-stage, non-root, sans secret)

# ---- base : manifestes npm uniquement (couche invalidée seulement si les dépendances changent)
FROM node:20.18.1-alpine3.21 AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ---- deps-dev : toutes les dépendances, pour les tests
FROM base AS deps-dev
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# ---- test : lint + tests unitaires exécutés pendant le build
FROM deps-dev AS test
COPY src ./src
COPY test ./test
RUN npm run lint && npm test && touch /tmp/tests-passed

# ---- deps-prod : dépendances de production uniquement
FROM base AS deps-prod
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# ---- runtime : image finale
# alpine nu + binaire node copié depuis l'image officielle : ni npm, ni yarn, ni corepack
# (≈ 45 Mo de moins et moins de surface d'attaque / CVE)
FROM alpine:3.21.2 AS runtime
COPY --from=base /usr/lib/libstdc++.so.6 /usr/lib/libgcc_s.so.1 /usr/lib/
COPY --from=base /usr/local/bin/node /usr/local/bin/node
RUN addgroup -g 1000 node && adduser -u 1000 -G node -s /bin/sh -D node
WORKDIR /app
# Dépendance explicite sur l'étape test : l'image finale ne se construit pas si les tests échouent
COPY --from=test /tmp/tests-passed /tmp/tests-passed
COPY --from=deps-prod --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
# Métadonnées en dernier : changer GIT_SHA à chaque commit n'invalide aucune couche de fichiers
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/shop-sas/shopapi
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.21.2"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000
USER node
EXPOSE 3000
# Healthcheck en node pur : fonctionne aussi sur une image sans shell ni wget (distroless)
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:'+(process.env.PORT||3000)+'/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
# Forme exec : node est PID 1 et reçoit directement SIGTERM (géré par server.js)
CMD ["node", "src/server.js"]
