# TP01 — Livrable 2 : rapport avant / après

- Diagnostic (livrable 1) : [`DIAGNOSTIC.md`](DIAGNOSTIC.md)
- Dockerfile final : [`shopapi/Dockerfile`](shopapi/Dockerfile) + [`shopapi/.dockerignore`](shopapi/.dockerignore)
- Variante distroless (B1) : [`shopapi/Dockerfile.distroless`](shopapi/Dockerfile.distroless)
- Sorties brutes : [`measures-legacy.txt`](measures-legacy.txt), [`measures-final.txt`](measures-final.txt)

Le code applicatif (`src/`, `test/`, `package.json`) n'est **pas modifié**. Seul ajout : `package-lock.json`,
généré une fois (`npm install --package-lock-only` dans `node:20.18.1-alpine3.21`) et à versionner,
indispensable à `npm ci` et à la reproductibilité.

> **Mise à jour (TP03)** : le scan trivy du TP03 a trouvé 25 CVE HIGH/CRITICAL corrigeables dans la base
> `alpine:3.21.2` / `node:20.18.1` (OpenSSL, musl, zlib). Le Dockerfile utilise désormais
> `node:20.20.2-alpine3.23` et `alpine:3.23.7` : 0 CVE HIGH/CRITICAL, image de 175 Mo, mêmes contrôles
> validés (non-root, `healthy`, hadolint vide). Les mesures ci-dessous datent de la première version.

## Tableau avant / après

Mesures sur Docker Desktop 28.4 (Linux, store d'images containerd).

| Critère | `shopapi:legacy` | `shopapi:1.4.2` |
|---|---|---|
| Taille (`docker image ls`) | **1,09 Go** | **171 Mo** |
| Taille compressée (pull réseau, `inspect .Size`) | 286 Mo | 45 Mo |
| Couches de fichiers (`.RootFS.Layers`) | 9 | 9 (dont 4 de quelques Ko) |
| Rebuild après `// commentaire` dans `server.js` | 10,8 s (`npm install` rejoué) | **2,0 s** (`npm ci` `CACHED`, seuls `COPY src` + tests rejoués) |
| Rebuild sans changement | 0,8 s | 1,0 s |
| Utilisateur | `uid=0(root)` | `uid=1000(node)` |
| PID 1 | `/bin/sh -c npm start` | `node src/server.js` |
| `time docker stop` | **10,2 s** (SIGKILL) | **0,2 s** (log `"signal":"SIGTERM","msg":"arrêt demandé"`) |
| Secrets (`env`, `.env`) | `DATABASE_URL` avec mot de passe, clé AWS | aucun |
| Fichiers inutiles | `.env`, `dump-prod-2024.sql`, `Dockerfile`, `test/` | aucun (`node_modules`, `package.json`, `src`) |
| Dépendances de dev | `eslint`, `nodemon` (+ nodemon global) | aucune (`.bin` : `mime pino`) |
| Healthcheck | aucun | `healthy` |
| Labels OCI | aucun (sauf `version=22.04` hérité d'ubuntu) | title, version, revision, source, vendor, base.name |
| hadolint | 5 warnings + 5 infos | **sortie vide** (exit 0) |

## Choix techniques

**Multi-stage** : `base` (manifestes npm) → `deps-dev` (`npm ci`) → `test` (`npm run lint && npm test`)
et `base` → `deps-prod` (`npm ci --omit=dev`) → `runtime`.

**Tests dans le build** : BuildKit ne construit que les étapes dont la cible dépend. Pour que
`docker build` (cible par défaut) exécute les tests, l'étape `runtime` copie un fichier témoin
`/tmp/tests-passed` produit par l'étape `test` : si les tests échouent, l'image finale n'est pas produite.
`docker build --target test` reste disponible pour la CI.

**Base runtime `alpine:3.21.2` + binaire node copié depuis `node:20.18.1-alpine3.21`** plutôt que
`node:20-alpine` directement : on retire npm, yarn et corepack (inutiles à l'exécution, ≈ 45 Mo et
plusieurs CVE récurrentes dans les dépendances de npm). Le binaire `node` n'a besoin que de
`libstdc++.so.6` et `libgcc_s.so.1` (vérifié avec `ldd`), copiés depuis la même image.
Avec `node:20.18.1-alpine3.21` comme runtime, l'image faisait 207 Mo dans `docker image ls` (157 Mo décompressés).
Pourquoi pas `slim` : glibc/Debian = image plus lourde, sans besoin de modules natifs ici (`pg` utilise le client JS pur).

**Cache** : `package.json` et `package-lock.json` sont copiés avant `npm ci` ; les sources après.
Les `ARG`/`LABEL` qui changent à chaque commit (`GIT_SHA`) sont placés **à la fin** : vérifié, un build avec
un autre `GIT_SHA` garde les 8 étapes de fichiers du runtime `CACHED`. `.dockerignore` en liste blanche
(`*` puis `!package*.json !src/ !test/`) : impossible d'embarquer par erreur un nouveau `.env`.

**Arrêt propre** : `CMD ["node", "src/server.js"]` en forme exec → node est PID 1 et reçoit directement
`SIGTERM`, que `server.js` gère (`server.close()`). Avec la forme shell, `/bin/sh` est PID 1 ; or un PID 1
n'a pas les handlers de signaux par défaut et `sh` ne relaie pas le signal à `npm`, qui ne le relaie pas à
`node` : Docker attend 10 s (`--stop-timeout`) puis envoie `SIGKILL`.
Remarque : node en PID 1 ne récupère pas les zombies ; l'app ne lance pas de sous-processus, donc pas
besoin de `tini` (sinon `docker run --init` ou `ENTRYPOINT ["tini","--"]`).

**Healthcheck** en `node -e` (requête HTTP sur `/health`) plutôt que `wget`/`curl` : aucun outil
supplémentaire, et la même commande fonctionne sur distroless.

## Bonus

### B1 — distroless

`shopapi:1.4.2-distroless` (`gcr.io/distroless/nodejs20-debian12:nonroot`) : 188 Mo, `healthy`,
utilisateur `65532`, `docker stop` 0,16 s.

Compromis :
- **pas de shell** : `docker exec apid sh` → `exec: "sh": executable file not found` ; pour déboguer il faut
  `docker debug`, un conteneur éphémère qui partage le namespace PID (`docker run --pid=container:apid
  --network=container:apid -it busybox`) ou la variante `:debug` de l'image ;
- **healthcheck sans wget** : `CMD ["/nodejs/bin/node", "-e", "require('http').get(...)"]` en forme exec
  (la forme shell `CMD-SHELL` est impossible sans `/bin/sh`) ;
- surface d'attaque minimale (pas d'apk/apt, pas de busybox), mais base Debian/glibc plus grosse qu'alpine
  ici, et `CMD` ne contient que le script car l'`ENTRYPOINT` est déjà `node`.

### B2 — cache mount npm

`docker build --target deps-dev` après avoir vidé le cache de couches (2 essais) :

| Scénario | Essai 1 | Essai 2 |
|---|---|---|
| `docker builder prune -af` (couches **et** cache mount vidés) | 7,8 s | 6,6 s |
| `docker builder prune -af --filter type!=exec.cachemount` (couches vidées, cache npm conservé) | 5,2 s | 5,3 s |

Avec le cache mount, `npm ci` récupère les tarballs depuis `/root/.npm/_cacache` au lieu du réseau :
≈ 20-30 % de gain ici (≈ 200 paquets, bonne connexion), bien plus sur des runners CI au réseau lent ou
avec beaucoup de dépendances. Le cache mount n'apparaît jamais dans l'image finale.

**Piège mesuré** : `docker build --no-cache` ne permet **pas** de démontrer le gain, car sur BuildKit
v0.24 (Docker Desktop 28.4) `--no-cache` fournit aussi un cache mount **vide** (vérifié avec
`du -sh /root/.cache/…` → `4.0K` à chaque build `--no-cache`). De même, un simple `docker builder prune -f`
supprime le cache mount s'il n'est pas utilisé. Détails dans le rapport du TP02.

### B3 — reproductibilité (non réalisé, analyse)

Ce qui empêche deux builds de donner le même digest : horodatages des fichiers (mtime) et de la config
de l'image (`created`), contenu de `npm ci` si le lockfile n'est pas versionné, images de base non
épinglées par digest, fichiers générés (`/tmp/tests-passed`, caches npm) dont la date change.
Solution : `SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)` +
`docker buildx build --output type=oci,dest=img.tar,rewrite-timestamp=true`, `FROM image@sha256:…`.
