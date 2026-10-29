# TP02 — BuildKit avancé : rapport

Livrables :
- Dockerfile final : [`shop-worker/Dockerfile`](shop-worker/Dockerfile) (+ `.dockerignore`, `.gitignore` qui exclut `pip.conf`)
- [`docker-bake.hcl`](docker-bake.hcl)
- Sorties brutes : [`leak-logs.txt`](leak-logs.txt), [`secret-check.txt`](secret-check.txt),
  [`cache-measures.txt`](cache-measures.txt), [`multiarch.txt`](multiarch.txt), [`bake.txt`](bake.txt),
  [`attestations.txt`](attestations.txt)

Environnement : Docker Desktop 28.4 (Linux), builder `desktop-linux` (BuildKit v0.24.0) et builder
`shop` en driver `docker-container` (BuildKit v0.33.1, `--driver-opt network=host` pour joindre
`localhost:5000`). Le registre de l'étape 4/5 est un `registry:2.8.3` temporaire sur `localhost:5000`
(le registre sécurisé est l'objet du TP03).

## 1. Prouver la fuite

Le build avec `pypi.internal.example.com` échoue (`Name or service not known`, pip masque le mot de
passe dans ses logs : `https://svc-ci:****@…`). Pour obtenir une image, le même Dockerfile a été construit
avec `--build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple` (pypi.org ignore l'identifiant).

Le secret est visible à **quatre** endroits :

| Où | Preuve |
|---|---|
| `docker history --no-trunc` | `RUN \|1 PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple /bin/sh -c pip install …` et la ligne `ARG PIP_INDEX_URL=…` |
| Config JSON de l'image (`docker save` / registre / `docker inspect` côté historique) | `grep -r Tr3sS3cret` trouve le blob de configuration ; tout utilisateur qui peut **pull** l'image le lit |
| Enregistrement du build BuildKit | `docker buildx history inspect` → tableau `BUILD ARG  PIP_INDEX_URL  https://svc-ci:Tr3sS3cret@…` (et les attestations de provenance en `mode=max` si activées) |
| Couche de fichiers | `COPY . .` embarque `pip.conf.example` qui contient `index-url = https://svc-ci:Tr3sS3cret@…` (`docker run … cat /app/pip.conf.example`) |

Remarque : `docker history … | grep -i secret` de l'énoncé ne trouve rien car le mot de passe est
`Tr3sS3cret` (« S3cret » avec un 3) : il faut chercher `s3cret`. L'image legacy fait en plus **1,71 Go**
(`python:3.12` complet + pytest/ruff + cache pip de 16 Mo dans `/root/.cache/pip`).

## 2. Secret mount

```dockerfile
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements.txt
```

Build : `docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .` (`pip.conf` local gitignored,
pointant sur `https://pypi.org/simple`).

Vérification avec un `pip.conf` contenant `https://svc-ci:Tr3sS3cret@pypi.org/simple` :
- `docker history --no-trunc … | grep -ci s3cret` → `0` ;
- `docker run --rm worker:secretcheck cat /etc/pip.conf` → `No such file or directory` ;
- `docker save` + recherche dans **toutes** les couches et la config → `0 occurrence(s)` ;
- la provenance BuildKit n'enregistre que `{"id": "pipconf"}`, jamais la valeur.

Le secret est monté en `tmpfs` le temps d'**un seul `RUN`** ; il ne fait pas partie de la clé de cache
(changer le mot de passe ne réinvalide pas la couche).

Image finale `worker:1.0` : `python:3.12.7-slim-bookworm`, venv `/opt/venv` copié depuis `builder`,
**217 Mo** (contre 1,71 Go), `uid=10001(worker)`, sans pytest/ruff, `/app` ne contient que `worker/`,
`HEALTHCHECK` sur `/metrics` (`healthy`), `docker stop` en 0,18 s (log `worker arrêté proprement`).
Les tests (`ruff check` + `pytest` : 2 passed) tournent dans l'étape `test`, dont `runtime` dépend via un
fichier témoin.

**Alternatives** :
- `RUN --mount=type=ssh pip install git+ssh://git@github.com/shop/private-lib.git` avec
  `docker build --ssh default` : l'agent SSH de l'hôte est relayé, la clé privée n'entre jamais dans le build ;
  utile pour les dépendances dans des dépôts git privés.
- `docker build --secret id=PIP_TOKEN,env=PIP_TOKEN` + `RUN --mount=type=secret,id=PIP_TOKEN,env=PIP_INDEX_URL pip install …`
  (le secret devient une variable d'environnement **du seul `RUN`**) : pratique en CI où les secrets sont des
  variables (GitHub Actions `secrets.*`), sans écrire de fichier.

## 3. Cache mount — mesures

Builder `desktop-linux`, connexion fibre. Détail : [`cache-measures.txt`](cache-measures.txt).

| Scénario | Temps | Paquets téléchargés / depuis le cache pip |
|---|---|---|
| A. Build à froid (`builder prune -af`) | 13,0 s | 8 / 0 |
| B. `builder prune -f` puis ajout de `requests` | 11,8 s | 13 / 0 |
| C. Ajout de `requests` avec cache pip vide | 13,6 s | 13 / 0 |
| D. `--no-cache` | 12,2 s | 13 / 0 |
| **E. Ajout de `requests` + `six`, sans prune** | **7,6 s** | **6 / 16** |

**Cache de couches vs cache mount**
- Le **cache de couches** mémorise le *résultat* d'une instruction (un snapshot de système de fichiers) indexé par
  l'instruction + ses entrées (fichiers copiés, args). C'est tout ou rien : un octet de `requirements.txt` change
  → la couche `pip install` est entièrement rejouée.
- Le **cache mount** est un répertoire persistant du builder, monté pendant un `RUN`, qui **n'entre pas dans
  l'image** et **survit à l'invalidation** de la couche. Quand la couche est rejouée (scénario E), pip retrouve
  dans `/root/.cache/pip` les wheels déjà téléchargés : seules les nouvelles dépendances (`requests`, `six` et leurs
  4 dépendances) passent par le réseau. 16 paquets « Using cached », 7,6 s au lieu de 13,6 s.

**Écart constaté avec l'énoncé** : sur cette version de BuildKit, `docker builder prune -f` **supprime aussi le
cache mount** dès qu'il n'est pas utilisé par un build en cours (scénario F : 1 cache mount avant, 0 après,
il est affiché `RECLAIMABLE true` dans `docker buildx du`). C'est pourquoi le scénario B de l'énoncé ne montre
aucun gain ; le scénario E (sans prune) montre le comportement attendu. Pour protéger le cache mount :
`docker builder prune --filter type!=exec.cachemount` ou `--keep-storage`.

**Avec `--no-cache`** : toutes les couches sont reconstruites **et** BuildKit fournit un cache mount neuf et vide
(scénario D : 13 téléchargements, constaté aussi sur un Dockerfile minimal avec `du -sh /root/.cache/pip` → `4.0K`).
`--no-cache` garantit donc un build réellement « from scratch ».

## 4. Multi-architecture

```bash
docker buildx create --name shop --driver docker-container --driver-opt network=host --use
docker buildx build --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf \
  -t localhost:5000/shop-worker:1.0 --push .                       # 1 min 22 s
docker buildx imagetools inspect localhost:5000/shop-worker:1.0
```

Mesures par étape (amd64 natif vs arm64 émulé par QEMU) :

| Étape | amd64 | arm64 (QEMU) |
|---|---|---|
| `pip install -r requirements.txt` | 2,8 s | 12,3 s |
| `pip install -r requirements-dev.txt` | 2,9 s | 22,5 s |
| `ruff check` + `pytest` | 0,5 s | 3,9 s |

`docker run --rm --platform linux/arm64 localhost:5000/shop-worker:1.0 python -c "import platform; print(platform.machine())"` → `aarch64`.

**Pourquoi `--push` ou `-o` est obligatoire** : le store d'images classique du daemon (et `--load`) ne sait
stocker qu'**une** image par tag pour une plateforme. Un résultat multi-plateforme est un *index* qui
référence plusieurs images ; il faut donc l'exporter vers un registre (`--push`) ou un fichier OCI
(`-o type=oci,dest=worker.tar`). Sans sortie, buildx l'indique : `WARNING: No output specified with
docker-container driver. Build result will only remain in the build cache`.

**Contenu du manifest list** (`application/vnd.oci.image.index.v1+json`, digest `sha256:3de48df5…`) :
un manifeste par plateforme (`linux/amd64` → `sha256:f432356c…`, `linux/arm64` → `sha256:55bf8a23…`),
plus deux manifestes `unknown/unknown` de type `attestation-manifest` (provenance générée par défaut par
buildx) rattachés chacun à une image via l'annotation `vnd.docker.reference.digest`. Le client qui fait
`docker pull` choisit le manifeste correspondant à son architecture.

**`TARGETARCH`** : argument automatique de BuildKit (`amd64`, `arm64`), déclaré par `ARG TARGETARCH` dans
l'étape. Il est utilisé dans l'id du cache mount : `id=pip-${TARGETARCH}` → deux caches séparés `pip-amd64` et
`pip-arm64` (visible dans les logs du build). Sans cela, les deux builds parallèles partageraient le même
cache et se marcheraient dessus (wheels d'une architecture différente, verrous).

**Lenteur arm64** : sur une machine amd64, chaque instruction arm64 est **traduite** par QEMU en mode
utilisateur (binfmt_misc) : 4 à 8× plus lent ici, bien pire pour une compilation C. Alternatives :
- **builders natifs** : un nœud arm64 (Graviton, Mac M) ajouté au même builder :
  `docker buildx create --name shop --append --platform linux/arm64 ssh://ci@arm-runner` ;
  buildx envoie chaque plateforme sur le nœud natif correspondant ;
- **compilation croisée** dans le Dockerfile (`FROM --platform=$BUILDPLATFORM` + `TARGETARCH`) pour les
  langages qui le permettent (Go, Rust) : l'étape de build tourne nativement, seule l'image finale est arm64.

## 5. Cache distant

```bash
docker buildx build --cache-to type=registry,ref=localhost:5000/cache:worker,mode=max \
                    --cache-from type=registry,ref=localhost:5000/cache:worker ...
```

| Scénario | Temps | Étapes `CACHED` |
|---|---|---|
| 1er build (cache distant inexistant : `localhost:5000/cache:worker: not found`, non bloquant) | 17,0 s | 0 |
| Nouveau builder vierge (= autre runner CI) **avec** `--cache-from` | **4,3 s** | 14 |
| Nouveau builder vierge **sans** `--cache-from` | 18,0 s | 0 |

**`mode=min` vs `mode=max`** :
- `min` (défaut) : n'exporte que les couches de l'**image finale** → 9 blobs, 53 Mo ;
- `max` : exporte les couches de **toutes les étapes** (builder, test) → 18 blobs, 75 Mo.
En multi-stage, `mode=max` est nécessaire pour que les étapes intermédiaires (`pip install` dev, tests)
soient aussi en cache ; plus lourd à pousser/stocker.

Variantes CI : `type=gha` (cache GitHub Actions, sans registre, quota 10 Go par dépôt),
`type=s3` (bucket S3/MinIO, `region`, `bucket`, `name`), `type=local,dest=…` (dossier mis en cache par la CI),
`type=inline` (métadonnées de cache dans l'image elle-même, `mode=min` uniquement).

## 6. `docker buildx bake`

[`docker-bake.hcl`](docker-bake.hcl) : variables `VERSION`, `GIT_SHA`, `REGISTRY` ; cible abstraite `_common`
(plateformes amd64/arm64, labels OCI, arg `GIT_SHA`) ; cibles `api` (contexte du TP01) et `worker`
(secret `pipconf`) avec cache registre `mode=max` ; groupe `default` ; `worker-test` qui hérite de `worker`
avec `target = "test"` et `output = ["type=cacheonly"]` (exécute lint + tests sans produire d'image).

| Commande | Résultat |
|---|---|
| `docker buildx bake --print` | plan JSON résolu (cf. `bake.txt`) |
| `VERSION=1.0 GIT_SHA=… docker buildx bake worker-test` | `All checks passed!`, `2 passed` |
| `VERSION=1.0 docker buildx bake --set '*.platform=linux/amd64' --load` | 17 s, `localhost:5000/shopapi:1.0` (171 Mo) et `localhost:5000/shop-worker:1.0` (217 Mo) chargées, labels `version=1.0`, `revision=<sha git>` |
| `VERSION=1.0 docker buildx bake --push` | 1 min 32 s, les 2 images en `linux/amd64` + `linux/arm64` |

## Bonus

### B2 — attestations provenance et SBOM

`docker buildx build --provenance=mode=max --sbom=true … --push` puis
`docker buildx imagetools inspect … --format '{{json .Provenance}}'` : provenance SLSA v1 (frontend
`dockerfile:1.7`, image de base `pkg:docker/python@3.12.7-slim-bookworm`, secrets listés **par id seulement**).
`--format '{{json .SBOM}}'` : SBOM SPDX de 124 paquets générés par `buildkit-syft-scanner`, dont
`redis 5.0.8`, `psycopg2-binary 2.9.9`, `prometheus-client 0.20.0`. C'est l'équivalent intégré au build du
`syft` + `cosign attest` du TP03.

### B1 — build sans réseau (non réalisé, analyse)

`RUN --network=none --mount=type=cache,…` ne suffit pas avec pip : même avec des wheels en cache, pip doit
interroger l'index pour résoudre les versions. Il faut un répertoire de wheels pré-téléchargé
(`pip download -d /wheels` dans une étape avec réseau, ou un cache mount dédié), puis
`pip install --no-index --find-links /wheels -r requirements.txt` en `--network=none`. Utile pour les builds
**hermétiques** : environnements isolés (défense, banque, santé), garantie que rien d'autre que les
dépendances déclarées n'est téléchargé (supply chain), reproductibilité.

### B3 — `uv` (non réalisé)

Remplacement par `COPY --from=ghcr.io/astral-sh/uv:<version> /uv /bin/uv` et
`RUN --mount=type=cache,target=/root/.cache/uv uv pip install --python /opt/venv/bin/python -r requirements.txt`
(avec `UV_LINK_MODE=copy` car le cache mount et le venv sont sur des systèmes de fichiers différents).
