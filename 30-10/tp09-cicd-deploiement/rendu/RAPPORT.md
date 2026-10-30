# TP09 — CI/CD : de la pull request au déploiement sans interruption : rapport

## Livrables

| Fichier | Rôle |
|---|---|
| [`shop/`](shop) | le dépôt `shop` : `apps/shopapi`, `apps/shop-worker`, stack compose TP04, `release-gate.sh` TP03 |
| [`shop/.github/workflows/ci.yml`](shop/.github/workflows/ci.yml) | pipeline GitHub Actions (validé par `actionlint` 1.7.7 + shellcheck) |
| [`shop/ci-local.sh`](shop/ci-local.sh) | rejoue le pipeline en local contre le registre du TP03 (`EVENT=pr\|main\|tag`) |
| [`shop/deploy/rolling-update.sh`](shop/deploy/rolling-update.sh) | déploiement sans interruption, rollback, redémarrage progressif (`FORCE=1`) |
| [`shop/deploy/measure-downtime.sh`](shop/deploy/measure-downtime.sh) | ~100 req/s sur `/health` via Traefik, bilan des échecs |
| [`shop/deploy/preprod-host/`](shop/deploy/preprod-host) | l'« hôte distant » : DinD + sshd, utilisateur `deploy` ; `setup.sh` crée le contexte `preprod` |
| [`shop/deploy/env/preprod.env`](shop/deploy/env/preprod.env) | variables **non secrètes** de l'environnement |
| `*.txt` | transcripts (pipeline, signatures, mesures, rollback) |

Le dépôt est un sous-dossier de ce dépôt-ci et pas un dépôt git imbriqué. Les tags `sha-<sha>` sont
donc ceux des commits de ce dépôt : chaque étape ci-dessous correspond à un vrai commit.

## 1. Le dépôt `shop`

Copie du rendu TP04 (applications, compose, smoke test, Makefile) et du `release-gate.sh` du TP03,
avec quatre modifications :

- **Chemins hôte paramétrés** : `${SECRETS_DIR:-./secrets}` et `${DB_INIT_DIR:-./db}`. Avec un daemon
  distant, un bind mount est résolu **sur le serveur**, et `./secrets/…` désignerait un chemin qui
  n'existe que sur le poste du développeur (cf. §3).
- **`compose.prod.yml`** :
  - `stop_grace_period: 15s` ;
  - middleware Traefik `retry` (3 tentatives) ;
  - healthcheck actif de Traefik sur **`/ready`** toutes les 2 s (cf. §4).
- **API** : vrai *drain* sur SIGTERM, ajouté pendant le TP, cf. §4.
- **Worker** : base `python:3.12.7` → `3.12.16-slim-bookworm`, imposé par la gate (§2).

## 2. Le pipeline

### Workflow GitHub Actions ([`ci.yml`](shop/.github/workflows/ci.yml))

| Événement | Jobs |
|---|---|
| `pull_request` | `lint` (hadolint ×2, `compose config` dev + prod) → `build` (matrice api/worker) : étape `test` du Dockerfile, puis build multi-arch **sans push** |
| `push` sur `main` | `build` : + login GHCR, **push** `sha-<sha>`, **trivy bloquant** (HIGH/CRITICAL corrigeables), **cosign keyless** → `deploy` (environment `preprod`) |
| tag `v*.*.*` | tags semver `X.Y.Z`, `X.Y`, `X` (sauf `v0.*`) → `deploy` (environment `production`, **reviewers obligatoires**) |

Points techniques imposés :

| Exigence | Mise en œuvre |
|---|---|
| tags + labels OCI | `docker/metadata-action@v5` : `type=sha,prefix=sha-,format=short` (politique TP03), `type=semver…`, `type=ref,event=pr` |
| cache | `type=gha,mode=max`, un `scope` par service (sinon api et worker s'écrasent mutuellement) |
| multi-arch | `setup-qemu-action` + `platforms: linux/amd64,linux/arm64` |
| matrice | `strategy.matrix.include` api/worker (contexte, nom d'image) |
| secret de build | `secrets: pipconf=${{ secrets.PIP_CONF }}` → `RUN --mount=type=secret,id=pipconf` (TP02) |
| provenance + SBOM | `provenance: mode=max`, `sbom: true` |
| signature keyless | `permissions: id-token: write` → `cosign sign` (Fulcio + Rekor), annotation `git_sha` |
| vérification au déploiement | `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp '^https://github.com/<repo>/.github/workflows/ci.yml@refs/(heads/main\|tags/v.*)$' -a git_sha=$GITHUB_SHA` |
| approbation prod | `environment: production` (reviewers configurés dans le dépôt) ; `concurrency` par environnement, jamais annulée |

Ordre des étapes dans `build` : **scan avant signature**. Une image vulnérable est poussée (sous
`sha-…`) mais n'est jamais signée, donc jamais déployable, puisque `deploy` vérifie la signature
avant toute action.

### Rejeu local ([`ci-local.sh`](shop/ci-local.sh))

Mêmes étapes, avec ces écarts assumés :

- cache **registre** au lieu de `gha` ;
- signature cosign **par clé** (celle du TP03) au lieu de keyless : il n'y a pas d'émetteur OIDC hors
  CI ;
- approbation prod = confirmation interactive.

Deux pièges rencontrés :

- le *credential store* `desktop` de ce poste est cassé (`pass not initialized`). Le script travaille
  donc dans un `DOCKER_CONFIG` isolé (`.ci/docker`, gitignoré), avec liens vers `cli-plugins`,
  `contexts` et `buildx` ;
- BuildKit parle **en HTTP clair** à tout registre `localhost:*` (`400 Bad Request` sur
  `http://localhost:5000/v2/…`). Il faut `http = false` explicite dans le `buildkitd.toml` du builder
  dédié `shop-ci`, en plus de la CA.

Résultats :

| Run | Résultat | Transcript |
|---|---|---|
| `EVENT=pr` | **vert** en 142 s : lint, tests, build amd64+arm64 sans push | [`ci-pr.txt`](ci-pr.txt) |
| `EVENT=main`, worker en `python:3.12.7` | **rouge** : la gate refuse `shop-worker` (**54 CVE HIGH/CRITICAL corrigeables**, toutes dans les paquets Debian 12.8 ; 0 côté pip). Rien n'est signé ni déployé | [`ci-main-gate-refus.txt`](ci-main-gate-refus.txt) |
| `EVENT=main` @ `4c3ddf8` (base 3.12.16) | **vert** en 163 s : gate ACCEPTÉ ×2, signé ×2, signatures vérifiées, premier déploiement préprod | [`ci-main-4c3ddf8.txt`](ci-main-4c3ddf8.txt) |
| `EVENT=main` @ `28013fb`, `9678ed6`, `da44a8f` | **verts** (84 à 170 s, cache registre) | `ci-main-*.txt` |
| `EVENT=main` @ `df7c20a` | **rouge (code 3)** : le garde-fou de `rolling-update.sh` refuse un changement de labels Traefik (§4) | [`ci-main-df7c20a-refus-labels.txt`](ci-main-df7c20a-refus-labels.txt) |

[`attestations.txt`](attestations.txt) : l'index `shopapi:sha-4c3ddf8` contient 2 images
(linux/amd64, linux/arm64) et 2 manifestes d'attestation (`https://spdx.dev/Document` et
`https://slsa.dev/provenance/v1`). Les signatures apparaissent sous la forme `sha256-<digest>.sig`.

[`signature-verif.txt`](signature-verif.txt) — vérification côté déploiement :

| Image | Résultat |
|---|---|
| `shopapi:sha-4c3ddf8`, `-a git_sha=4c3ddf8` | ✔ annotations, claims et clé vérifiées (rc=0) |
| `shopapi:sha-8990231` (poussée lors du run refusé par la gate) | `no signatures found` (rc=10) → **non déployable** |
| `shopapi:sha-4c3ddf8`, `-a git_sha=deadbee` | `missing or incorrect annotation` (rc=12) : une signature valide ne suffit pas, elle doit correspondre au commit déployé |

## 3. Déploiement distant

Il n'y a pas de sshd sur ce poste (et pas de droits root pour en installer un). L'« hôte distant » est
donc un conteneur [`preprod-host`](shop/deploy/preprod-host) :

- `docker:28.4.0-dind` + `openssh-server`, utilisateur `deploy` membre du groupe `docker` ;
- authentification par clé uniquement (`PasswordAuthentication no`, `PermitRootLogin no`,
  `AllowUsers deploy`) ;
- SSH publié sur `127.0.0.1:2222`, Traefik de la stack sur `127.0.0.1:18000` ;
- son propre daemon, sa propre CA de registre (`certs.d/registry.local:5000`).

[`setup.sh`](shop/deploy/preprod-host/setup.sh) génère une clé dédiée et démarre l'hôte. Il
provisionne ensuite `/srv/shop` puis exécute :
`docker context create preprod --docker host=ssh://deploy@preprod-lab`.

Le client docker appelle le `ssh` qu'il trouve dans le `PATH`. Un wrapper (`.ci/bin/ssh` →
`ssh -F .ci/ssh/config`) fournit donc l'alias `preprod-lab`, la clé et un `known_hosts` dédiés, sans
toucher à `~/.ssh`.

```
$ docker --context preprod info      → contexte preprod → preprod (28.4.0, 0 conteneurs)
serveur : deploy ∈ docker docker 28.4.0
```

**Prérequis côté serveur :**

- docker installé ;
- utilisateur `deploy` dans le groupe `docker`. Attention, ça revient à lui donner root : la clé SSH
  de déploiement est un secret critique. On la restreint à l'IP de la CI, on la change souvent, et on
  envisage `command="docker system dial-stdio"` dans `authorized_keys` ;
- `known_hosts` du serveur connu de la CI (`vars.DEPLOY_KNOWN_HOSTS`) : pas de *trust on first use*
  en CI ;
- le registre est joignable et de confiance. Ici, `registry.local:host-gateway` + CA TP03 : le même
  registre est vu sous un autre nom depuis le serveur, et les digests ne changent pas ;
- **`/srv/shop/secrets/db_password.txt` et `/srv/shop/db/` présents sur le serveur**, et absents de
  git.

**Comment les secrets arrivent en prod.** Avec un daemon distant, `docker compose` lit les fichiers
compose **localement**, mais le moteur résout les bind mounts **sur le serveur**. Compose affiche
d'ailleurs `secret file shop_db_password does not exist`, puisque le fichier n'est pas sur le poste
qui lance la commande.

- Le secret est donc **déposé sur le serveur, hors bande**. Ici, `setup.sh` le génère *sur* le
  serveur (`umask 077`, dossier 700), et il n'en sort jamais.
- En entreprise, il est déposé par Ansible/Vault ou par un job CI qui lit un secret d'environnement
  GitHub et l'écrit par `ssh` avec `umask 077`.
- `deploy/env/preprod.env` (versionné) ne contient que des chemins et des noms, aucune valeur
  secrète.
- La clé SSH et les identifiants du registre sont des **secrets d'environnement** GitHub
  (`DEPLOY_SSH_KEY`, `GITHUB_TOKEN`), donc disponibles seulement pour le job `deploy` de cet
  environnement.

## 4. Zéro interruption

Même protocole à chaque fois : `measure-downtime.sh` (~92 req/s effectives, timeout 2 s) pendant le
déploiement, puis bilan. Les itérations sont dans l'ordre réel :

| # | Déploiement | Requêtes | Échecs | Nature | Transcript |
|---|---|---|---|---|---|
| 0 | **naïf** `up -d --force-recreate api` | 2 750 | **540** | 500 × 404 (Traefik n'a plus aucun backend) + 40 × 502, fenêtre de 6,2 s | [`deploy-naif.txt`](deploy-naif.txt) |
| 1 | rolling v1 → `sha-28013fb` | 19 280 | **36** | 34 × timeout + 2 × 502, pendant l'arrêt de l'ancien réplica | [`rolling-v1-mesure.txt`](rolling-v1-mesure.txt) |
| 2 | rolling v2 → `sha-9678ed6` (drain ajouté, **labels modifiés**) | 18 800 | **1 470** | 404 sur 17 s | [`rolling-v2-mesure.txt`](rolling-v2-mesure.txt), [`rolling-v2-traefik.txt`](rolling-v2-traefik.txt) |
| 3 | rolling v3 → `sha-da44a8f` | 12 950 | **112** | 503 : le `/health` mesuré était aussi la sonde de drain | [`rolling-v3-mesure.txt`](rolling-v3-mesure.txt) |
| – | → `sha-df7c20a` : changement de label (`healthcheck.path`), **refusé** par le garde-fou ; forcé avec `ALLOW_LABEL_CHANGE=1` | 4 120 | 2 470 | 404 sur 26 s : le coût d'un changement de labels, que le garde-fou évite | [`rolling-garde-fou-labels.txt`](rolling-garde-fou-labels.txt), [`deploy-changement-labels.txt`](deploy-changement-labels.txt) |
| 5 | **rolling final** (`FORCE=1`, df7c20a → df7c20a) | 4 650 | **0** | | [`rolling-v5-final.txt`](rolling-v5-final.txt) |

Analyse de chaque itération :

- **v1, keep-alive.** Après SIGTERM, Traefik continue d'envoyer des requêtes sur ses connexions
  keep-alive vers le réplica, tant que le conteneur n'est pas mort : il ne l'apprend qu'à
  l'événement `die`. `server.close()` attend que ces connexions se ferment, ce qui n'arrive pas.
  L'`exit(1)` de sécurité, au bout de 10 s, coupe alors les requêtes en vol. On le voit au temps
  d'arrêt : 13 s pour `shop-api-1`.
  → **Drain applicatif** : à SIGTERM, l'API reste en service 5 s, ajoute `Connection: close` à
  chaque réponse et fait échouer sa sonde ; ensuite seulement `server.close()` +
  `closeIdleConnections()`. Healthcheck actif Traefik resserré à 2 s (< 5 s de drain).
- **v2, conflit de labels.** Traefik construit le service `api` à partir des labels de **tous** les
  conteneurs. Les anciens réplicas déclaraient `healthcheck.interval=5s`, les nouveaux `2s`. D'où
  `Service defined multiple times with different configurations`, puis
  `the service "api@docker" does not exist` : 404 pendant toute la cohabitation.
  → **Garde-fou** dans `rolling-update.sh` : il compare les labels `traefik.*` actuels et cibles et
  refuse le rolling si ils diffèrent (code 3, `ALLOW_LABEL_CHANGE=1` pour forcer en connaissance de
  cause). Une config de service qui doit changer souvent irait plutôt dans le provider fichier de
  Traefik.
- **v3, liveness/readiness.** La sonde de drain (`/health` → 503) était aussi l'endpoint mesuré : les
  clients recevaient le 503 pendant les ≤ 2 s où Traefik n'avait pas encore retiré le réplica.
  → **Séparation** : `/health` = liveness (toujours 200 tant que le processus sert), `/ready` =
  readiness (503 pendant le drain, et si db/redis sont KO). Traefik sonde `/ready`.

Fonctionnement final de [`rolling-update.sh`](shop/deploy/rolling-update.sh) :

```
pull → garde-fou labels → pour chaque ancien réplica :
   up --no-recreate --scale api=N+1   (crée UN réplica neuf, les anciens restent intacts)
   attendre State.Health = healthy     (HEALTHCHECK image / compose, start_period)
   sleep 3                             (Traefik : providersThrottleDuration 2 s)
   docker stop -t 15 ancien ; rm       (SIGTERM → drain 5 s → close → exit 0)
→ worker : up --no-deps --wait (consommateur de file : un redémarrage ne perd rien)
```

Un réplica neuf qui n'atteint pas `healthy` en 90 s est supprimé, et l'ancienne version reste en
service.

**Rôle de chaque brique, et ce qui se passe sans elle :**

| Brique | Rôle | Si on la retire |
|---|---|---|
| `HEALTHCHECK` image + healthcheck compose (`/ready`) | état `healthy` = prêt à servir | Traefik route dès le démarrage du conteneur, avant que l'API ait ouvert son port ou joint la base → 502 ; le script ne sait plus quand basculer |
| `start_period` | laisse démarrer sans compter d'échecs | un démarrage lent (migration, JIT) passe en `unhealthy` et le réplica neuf est jeté → rolling en échec |
| `--wait` | `up` ne rend la main qu'avec des services healthy | la CI enchaîne (smoke test, réplica suivant) sur un service pas prêt ; échec silencieux |
| SIGTERM géré + **drain** | finir les requêtes en vol et sortir du pool avant de fermer | v1 : timeouts et 502 à chaque arrêt |
| `stop_grace_period` / `stop -t 15` | délai avant SIGKILL, plus long que le drain (5 s) + la fin des requêtes | avec la valeur par défaut (10 s), un drain plus long serait tué par SIGKILL en plein milieu |
| réplicas ≥ 2 | il y a toujours un réplica qui sert pendant qu'on remplace l'autre | avec un seul réplica, le drain n'a nulle part où envoyer le trafic |
| reverse proxy (Traefik) | découverte dynamique et répartition ; ignore les conteneurs `starting`/`unhealthy` ; healthcheck actif ; `retry` sur connexion refusée | sans proxy, un port publié appartient à un seul conteneur : impossible d'en faire cohabiter deux |

## 5. Rollback ([`rollback.txt`](rollback.txt))

```
$ time DOCKER_CONTEXT=preprod VERSION=sha-da44a8f ./deploy/rolling-update.sh
…
real 0m43,665s           requêtes : 4590   succès : 4590   ÉCHECS : 0
$ curl -H 'Host: api.localhost' http://127.0.0.1:18000/   → {"service":"shopapi","version":"sha-da44a8f"}
```

Le rollback prend **44 s, sans aucun échec**. C'est la même mécanique qu'un déploiement, la durée
étant dominée par `start_period`, le délai Traefik et le drain, multipliés par le nombre de
réplicas.

Ce qui le rend possible :

- **tags immuables** `sha-<sha>` (TP03) : `sha-da44a8f` désigne toujours le même digest, et la
  signature est attachée au digest ;
- **images conservées** : dans le registre (rétention TP03 : les N dernières versions), et dans le
  cache de l'hôte, ce qui rend le `pull` instantané ;
- **configuration compatible** : les labels Traefik viennent des fichiers compose courants et pas de
  l'image. Revenir à une image est sans risque, revenir à un *commit* qui change les labels
  déclencherait le garde-fou ;
- **base compatible** : les deux versions utilisent le même schéma.

Le retour en avant depuis `da44a8f`
([`rolling-v4-depuis-da44a8f.txt`](rolling-v4-depuis-da44a8f.txt)) a donné **355 échecs**. Les
réplicas arrêtés étaient ceux de `da44a8f`, qui drainent encore « à l'ancienne » (503 sur `/health`).
**Un rollback ramène aussi l'ancien comportement d'arrêt** : un correctif de drain ne protège que les
déploiements où la version *sortante* l'a déjà.

**Migration de schéma non rétro-compatible** (renommer ou supprimer une colonne). Pendant un rolling,
v1 et v2 tournent en même temps sur la même base, et un rollback remet v1 sur un schéma v2. Il faut le
pattern **expand / contract** en trois déploiements :

1. *expand* : ajouter la nouvelle colonne (nullable ou avec défaut), sans rien casser pour v1 ;
2. déployer v2, qui écrit les deux colonnes et lit la nouvelle ; backfill en tâche de fond ;
3. *contract* : supprimer l'ancienne colonne, une fois qu'aucun rollback vers v1 n'est plus
   envisageable.

Chaque étape reste réversible sans restauration. Une migration destructive « d'un coup » implique
une sauvegarde préalable (TP05), et un rollback devient alors une **restauration**, avec perte des
écritures intervenues entre-temps.

## Bonus

Non traités (B1 Swarm, B2 GitOps pull, B3 `compose publish`, B4 tests d'intégration en CI). Pour B4,
`ci-local.sh` déploie déjà en préprod puis lance le smoke test : il ne manquerait que le
`compose up --wait` / `down -v` éphémère dans le job.

Non exécuté : le chemin **tag `v*`** de `ci-local.sh`. Il reconstruit les images, ce qui réécrirait
le tag `sha-<sha>` avec un nouveau digest (l'horodatage de provenance change). Dans le workflow, la
bonne pratique serait de **promouvoir** le digest déjà signé (`crane tag` / `imagetools create`)
plutôt que de reconstruire.
