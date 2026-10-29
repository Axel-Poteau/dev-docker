# TP01 — Livrable 1 : diagnostic de `shopapi:legacy`

Sorties brutes complètes : [`diag-logs.txt`](diag-logs.txt) et [`measures-legacy.txt`](measures-legacy.txt).
Dockerfile d'origine conservé dans [`shopapi/Dockerfile.legacy`](shopapi/Dockerfile.legacy).

## A. Taille / performance

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| 1 | **Image de 1,09 Go** basée sur `ubuntu:22.04` complet | `docker image ls shopapi:legacy` → `1.09GB` (286 Mo compressés) | Saturation du registre, pull lent sur chaque nœud, rolling update ralenti |
| 2 | **Outils de build et d'édition dans l'image finale** : `build-essential`, `vim`, `git`, `curl`, `wget`, `python3` | `docker history` → couche `apt-get install -y curl wget vim git build-essential python3` = **393 Mo** ; `which vim git gcc curl wget python3` les trouve tous | +400 Mo inutiles à l'exécution, et autant de paquets à patcher (cf. sécurité) |
| 3 | **`apt-get update` dans une couche séparée**, listes apt jamais supprimées | `docker history` → couche `apt-get update` = **81,5 Mo** ; hadolint `DL3009` | 81 Mo perdus ; cache apt périmé si l'`update` est en cache mais pas l'`install` |
| 4 | **Pas de `--no-install-recommends`** | hadolint `DL3015` (lignes 5 et 7) | Paquets recommandés installés en plus |
| 5 | **Invalidation du cache** : `COPY . /app` **avant** `npm install` | Après `echo "// commentaire" >> src/server.js`, l'étape `[9/9] RUN npm install` est rejouée (pas `CACHED`) : 0,8 s → **10,8 s** en local, ≈ 4 min en CI sans cache | Chaque commit (même un README) réinstalle toutes les dépendances |
| 6 | **Dépendances de dev dans l'image** (`nodemon`, `eslint`) + `nodemon` installé en global | `ls node_modules/.bin` → `eslint nodemon nodetouch …` ; couche `npm install -g nodemon` (7,5 Mo) | Taille + surface d'attaque, `NODE_ENV=development` |
| 7 | **Fichiers inutiles copiés** : `dump-prod-2024.sql`, `Dockerfile`, `.gitignore`, `test/` (pas de `.dockerignore`) | `ls -la /app` les liste | Le dump simule 50 Mo de données de prod dans chaque image |
| 8 | **Pas de lockfile / `npm install` au lieu de `npm ci`** | `package-lock.json` absent du dépôt, généré dans l'image à chaque build | Build **non reproductible** : versions `^x.y.z` résolues différemment d'un build à l'autre |
| 9 | Cache npm laissé dans `/root/.npm` | dive : `/root/.npm/_cacache/...` dans les fichiers « inefficaces » ; efficacité dive 99,6 % mais 4 Mo gaspillés (logs dpkg/apt, cache debconf) | Octets perdus dans chaque couche |

## B. Sécurité

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| 10 | **Secret en `ENV`** dans le Dockerfile | `docker run --rm shopapi:legacy env` → `DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop` ; aussi visible dans `docker history` et `docker inspect` | Toute personne qui peut tirer l'image lit le mot de passe de la base de prod |
| 11 | **Fichier `.env` copié dans l'image** (clé AWS) | `docker run --rm shopapi:legacy cat /app/.env` → `AWS_SECRET_ACCESS_KEY=AKIAFAKE…` | Fuite d'identifiants cloud ; détectable par `trivy --scanners secret` (TP03) |
| 12 | **Dump de base de prod** dans l'image | `ls -la /app` → `dump-prod-2024.sql` | Fuite de données (RGPD) |
| 13 | **Conteneur exécuté en root** | `docker run --rm shopapi:legacy id` → `uid=0(root)` ; `docker top` → tous les processus en `root` | Une RCE dans l'API donne root dans le conteneur (et plus si évasion) |
| 14 | **Script distant exécuté sans vérification** : `curl … \| bash -` | Dockerfile ligne 6 ; hadolint `DL4006` (pas de `pipefail`) | Supply chain : un échec de `curl` passe inaperçu, contenu non vérifié |
| 15 | **Versions non épinglées** (paquets apt, `nodemon`, Node via NodeSource « 20.x ») | hadolint `DL3008` ×2, `DL3016` | Builds non reproductibles, mises à jour non maîtrisées |
| 16 | Surface d'attaque : `gcc`, `git`, `curl`, `wget`, `vim` disponibles | cf. #2 | Un attaquant dispose d'un compilateur et d'outils de téléchargement |

## C. Exploitabilité

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| 17 | **`CMD` en forme shell** + `npm start` : PID 1 = `/bin/sh` | `docker inspect` → `"Cmd":["/bin/sh","-c","npm start"]` ; `docker top legacy` → `sh -c npm start` → `npm start` → `sh -c node …` → `node` ; hadolint `DL3025` | `SIGTERM` reçu par `sh` qui ne le relaie pas : **`docker stop` = 10,2 s** (timeout puis SIGKILL), connexions coupées net, rolling updates de 30 s |
| 18 | **Pas de `HEALTHCHECK`** | `docker inspect` → `"Healthcheck":null` | L'orchestrateur ne sait pas si l'API répond : trafic envoyé sur une instance cassée |
| 19 | **Pas de labels OCI** applicatifs (seul `org.opencontainers.image.version=22.04` hérité d'ubuntu, faux) | `docker inspect … .Config.Labels` | Impossible de tracer image → version → commit git |
| 20 | `NODE_ENV=development` en prod | `docker inspect` (Env) | Express en mode dev : stacktraces verbeuses, perfs moindres |
| 21 | Tests jamais exécutés au build | Pas d'étape `npm test` | Une régression peut être publiée |

## Ordre des couches idéal (étape 2)

Pourquoi `npm install` est rejoué : le cache de couches est invalidé **en cascade**. `COPY . /app` calcule
un checksum de tout le contexte ; un seul octet modifié dans `src/server.js` invalide cette couche et donc
**toutes les suivantes**, dont `RUN npm install`.

Ordre idéal, du moins volatil au plus volatil :

```
FROM image de base épinglée          ← change ~ tous les mois (mise à jour sécurité)
WORKDIR /app
COPY package.json package-lock.json  ← change quand on ajoute/met à jour une dépendance
RUN npm ci                           ← rejoué seulement si la ligne précédente change
COPY src/                            ← change à chaque commit
CMD / HEALTHCHECK / LABEL dynamiques ← métadonnées (les LABEL avec GIT_SHA en dernier)
```
