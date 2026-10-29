# TP04 — Stack Compose d'entreprise : rapport

## Livrables

| Fichier | Rôle |
|---|---|
| [`compose.yml`](compose.yml) | base commune à tous les environnements |
| [`compose.override.yml`](compose.override.yml) | surcharge dev (appliquée automatiquement) |
| [`compose.prod.yml`](compose.prod.yml) | surcharge prod |
| [`compose.watch.yml`](compose.watch.yml) | bonus B1 : `docker compose watch` |
| [`.env.example`](.env.example) | variables non secrètes (`REGISTRY`, `VERSION`, ports) |
| [`Makefile`](Makefile) | `make up / test / migrate M=… / release / prod-up / prod-test …` |
| [`smoke-test.sh`](smoke-test.sh) | test de bout en bout via Traefik |
| [`db/init.sql`](db/init.sql), [`db/migrations/002-add-sku.sql`](db/migrations/002-add-sku.sql) | schéma initial, migration |
| `apps/shopapi`, `apps/shop-worker` | images des TP01 et TP02 |
| `*.txt` | transcripts : [`dev-checks.txt`](dev-checks.txt), [`dev-reload.txt`](dev-reload.txt), [`prod.txt`](prod.txt), [`make.txt`](make.txt) |

Démarrage : `make up` (crée `.env`, `secrets/db_password.txt` aléatoire et `pip.conf` s'ils n'existent pas),
puis `make test`.

Spécificité du poste : Apache écoute déjà sur le port 80 et un PostgreSQL local sur le 5432. Les ports
publiés sont donc paramétrés : `HTTP_PORT` (80 par défaut, **8000** dans `.env`) et `DB_DEBUG_PORT`
(5432 par défaut, **15432** dans `.env`). Les URL deviennent `http://api.localhost:8000`.

## 1. Critique du `docker-compose.yml` d'origine

| # | Problème | Conséquence |
|---|---|---|
| 1 | `version: '3'` | clé obsolète, ignorée par Compose v2 (avertissement) ; laisse croire à une compatibilité de format |
| 2 | `links:` | fonctionnalité legacy ; la résolution DNS par nom de service sur un réseau utilisateur suffit |
| 3 | Images **non épinglées** (`postgres`, `redis`) | `latest` implicite : une montée de version majeure de PostgreSQL au prochain `pull` empêche la base de démarrer (cf. TP05) |
| 4 | Ports **5432 et 6379 publiés** sur `0.0.0.0` | base et Redis (sans mot de passe) accessibles depuis le réseau, voire Internet |
| 5 | Port 3000 de l'API publié directement | pas de reverse proxy, pas de TLS ni de répartition de charge ; impossible d'avoir plusieurs réplicas sur le même port |
| 6 | **Mots de passe en clair** (`POSTGRES_PASSWORD: postgres`, dans les deux `DATABASE_URL`) | versionnés dans git, visibles par `docker inspect` ; mot de passe trivial ; utilisateur superadmin `postgres` utilisé par l'application |
| 7 | `sleep 10 && node …` | démarrage non fiable : trop court si la base est lente, du temps perdu sinon ; `sh -c` en PID 1 ne relaie pas `SIGTERM` (arrêt en 10 s) |
| 8 | Aucun `healthcheck` | `depends_on` n'attend que le démarrage du conteneur, pas sa disponibilité ; `up --wait` impossible |
| 9 | **Réseau unique** (`default`) | tous les services se voient ; aucune segmentation front/back |
| 10 | **Pas de volume nommé** pour `db` | volume anonyme créé par l'image : perdu au `docker compose rm` / `down -v`, difficile à identifier et sauvegarder ; Redis sans persistance |
| 11 | `restart` incohérent | `always` seulement sur le worker ; la base et l'API ne redémarrent pas après un crash ou un reboot |
| 12 | Pas de limites CPU/mémoire | un service qui fuit peut faire tomber l'hôte |
| 13 | Pas de rotation des logs | le driver `json-file` remplit le disque |
| 14 | `build:` sans image taguée | impossible de distinguer dev et prod, de pousser ou de déployer une version précise |
| 15 | Pas de nom de projet | le projet prend le nom du dossier : volumes/réseaux différents d'un poste à l'autre |

## 2. Fichier de base `compose.yml`

- `name: shop` : réseaux `shop_front`/`shop_back`, volumes `shop_pgdata`/`shop_redisdata` stables.
- Réseaux : `front` (proxy, API, adminer) et `back` **`internal: true`** (API, worker, db, redis).
- Images épinglées : `postgres:16.4-alpine`, `redis:7.4-alpine`, `traefik:v3.1.7`.
- Ancres YAML : `x-healthcheck-defaults` (fusionné dans chaque healthcheck), `x-logging` (rotation
  10 Mo × 3), `x-service-defaults` (`restart: unless-stopped` + logging), `x-database-env`.
- `depends_on: condition: service_healthy` partout ; healthchecks : `traefik healthcheck --ping`,
  `/ready` pour l'API (vérifie db **et** redis), `/metrics` pour le worker, `pg_isready`, `redis-cli ping`.
- **Secret** : `secrets/db_password.txt` (gitignoré, `openssl rand -hex 24`), monté dans
  `/run/secrets/db_password` ; `POSTGRES_PASSWORD_FILE` côté base.
- **`DATABASE_URL` sans modifier le code** : entrypoint commun (ancre `x-database-url-entrypoint`) qui
  lit le secret, exporte l'URL puis fait `exec "$@"` :
  ```yaml
  entrypoint: ["/bin/sh", "-c", 'export DATABASE_URL="postgres://$${DB_USER}:$$(cat /run/secrets/db_password)@$${DB_HOST}:5432/$${DB_NAME}"; exec "$$@"', "--"]
  command: ["node", "src/server.js"]
  ```
  Le `exec` garde l'application en PID 1 (`ps` → `1 node node src/server.js`) ; l'URL n'existe que dans
  l'environnement du processus : ni `docker inspect`, ni `docker compose exec api env` ne la montrent.
  Le mot de passe est hexadécimal pour ne pas avoir à l'encoder dans l'URL.
- Volumes nommés `pgdata` et `redisdata` (Redis en `--appendonly yes`), `db/init.sql` monté dans
  `docker-entrypoint-initdb.d`.
- Traefik piloté par labels : `Host(\`api.localhost\`)` → port 3000, healthcheck de backend `/health`
  toutes les 5 s, `exposedbydefault=false`, configuration statique par variables `TRAEFIK_*`.
- Profils : `tools` (adminer, routé sur `adminer.localhost`) et `ops` (`migrate`, `restart: "no"`,
  `psql -v ON_ERROR_STOP=1 -f /migrations/$MIGRATION`).
- Le worker est construit avec le secret de build `pipconf` (TP02) déclaré dans `secrets:`.

Validation ([`dev-checks.txt`](dev-checks.txt)) :

| Vérification | Résultat |
|---|---|
| `docker compose up -d --build --wait` | tous les services `healthy`, rend la main après les healthchecks |
| `/ready` via Traefik | `{"status":"ready","checks":{"db":"ok","redis":"ok"}}` |
| `/products` ×2 | `X-Cache: MISS` puis `HIT` |
| `POST /orders` | commande `confirmed` par le worker (`commande … -> confirmed` dans ses logs) |
| `MIGRATION=002-add-sku.sql docker compose run --rm migrate` | `ALTER TABLE`, `UPDATE 3` ; rejouée : `NOTICE … already exists, skipping`, `UPDATE 0` |
| `docker compose run --rm migrate` sans `MIGRATION` | `variable MIGRATION requise`, exit 2 |
| `shop_back` | `Internal: true` ; le worker n'a pas d'accès Internet (`Temporary failure in name resolution`) ; l'API, aussi sur `front`, sort normalement |
| Redis depuis `shop_front` | `Name does not resolve` ; depuis `shop_back` : `PONG` ; aucun port publié |

## 3. Surcharge dev `compose.override.yml`

Bind mount `./apps/shopapi/src:/app/src:ro` + `node --watch`, ports 3000, 15432 (base) et 8080
(dashboard Traefik via `TRAEFIK_API_INSECURE`), `LOG_LEVEL=debug`.

Pour publier le port de la base : un conteneur uniquement relié à un réseau `internal` **ne peut pas**
publier de port. La base est donc rattachée en dev à un réseau supplémentaire `debug` (non interne).

**Rechargement à chaud — constat sur Docker Desktop** ([`dev-reload.txt`](dev-reload.txt)) : avec le bind
mount, `node --watch` **ne redémarre pas**. Le partage de fichiers de la VM Docker Desktop ne relaie pas les
événements inotify ; pire, un fichier remplacé par renommage (`sed -i`, sauvegarde « atomique » des
éditeurs) n'est pas visible dans le conteneur. Sur Docker Engine natif (Linux sans VM), le bind mount
partage directement l'inode et le reload fonctionne. D'où le bonus B1.

## 4. Surcharge prod `compose.prod.yml`

`docker compose -f compose.yml -f compose.prod.yml up -d --wait` ([`prod.txt`](prod.txt)) :

- **`build: !reset null`** supprime la clé `build` héritée de la base ; `image:
  ${REGISTRY:?…}/shopapi:${VERSION:?…}` + `pull_policy: always` → images tirées du registre du TP03
  (`localhost:5000/shopapi:1.0`, `localhost:5000/shop-worker:1.0`, poussées par `make release`).
- `deploy.replicas: 2` pour l'API. **Répartition vérifiée dans les logs d'accès JSON de Traefik** :
  10 requêtes → 5 vers `http://172.22.0.3:3000` (`shop-api-2`) et 5 vers `http://172.22.0.4:3000` (`shop-api-1`).
- Limites CPU/mémoire sur tous les services (`docker stats` : 256 Mo pour l'API, 128 Mo worker/redis/proxy, 512 Mo db).
- Durcissement (ancre `x-hardening`) : `read_only: true` + `tmpfs: /tmp`, `cap_drop: [ALL]`,
  `no-new-privileges:true`. `touch /app/x` → `Read-only file system`, `/tmp` reste inscriptible.
  Exceptions documentées : Traefik garde `NET_BIND_SERVICE` (écoute sur 80) ; PostgreSQL garde
  `CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID` (son entrypoint démarre en root et bascule sur `postgres`) ;
  Redis démarre directement en `user: redis` (sinon son entrypoint tente un `chown` en root et échoue sans
  capacité : `find: ./appendonlydir: Permission denied`, constaté au premier essai).
- Aucun port de debug ni dashboard : `localhost:3000` et `localhost:8080` → connexion refusée ; seul le port HTTP du proxy est publié.

**`--scale api=3` puis `up -d`** : le scale crée `shop-api-3` ; le `up -d` suivant, sans `--scale`,
**réconcilie vers `deploy.replicas: 2`** et arrête/supprime `shop-api-3`. L'état voulu est celui du
fichier : un `--scale` manuel est temporaire et sera défait au prochain déploiement.

## 5. Outillage

`make help` liste les cibles ; transcript [`make.txt`](make.txt). `make prod-test` et `make test` :

```
Smoke test sur http://localhost:8000 (Host: api.localhost)
  ✔ /ready : {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  ✔ /products servi depuis Redis (X-Cache: HIT)
  ✔ commande créée : {"id":1793266868434,"productId":1,"status":"pending"}
  ✔ commande 4 confirmée par le worker
OK
```

`make clean` (`down -v`) demande une confirmation explicite : c'est la commande de l'incident du TP05.

## Bonus

### B1 — `docker compose watch`

[`compose.watch.yml`](compose.watch.yml) retire le bind mount (`volumes: !reset []`) et déclare
`develop.watch` : `sync+restart` sur `src/`, `rebuild` sur `package.json` / `package-lock.json`.
`make watch` ; résultat : 3 modifications successives → `{"edit":1}`, `{"edit":2}`, `{"edit":3}`, puis
retour à `{"status":"ok"}` après restauration (`service(s) ["api"] restarted` à chaque fois).

- `sync` copie les fichiers modifiés **dans** le conteneur (pas de dépendance au partage de fichiers de la VM).
  Avec `sync` seul + `node --watch`, seule la 1re modification était prise en compte (node 20 perd le
  fichier quand il est remplacé) → `sync+restart`.
- `rebuild` reconstruit l'image et recrée le conteneur : nécessaire quand les dépendances changent
  (`npm ci` est dans l'image), coûteux pour un simple changement de code.

### B3 — adminer et le réseau `internal`

Oui, adminer est joignable via `http://adminer.localhost:8000` (page « Login - Adminer » obtenue) : il est
attaché à **deux réseaux**. Traefik lui parle par `front` (`TRAEFIK_PROVIDERS_DOCKER_NETWORK=shop_front`), et adminer parle à la base par `back`. `internal: true` interdit seulement la
route vers l'extérieur du réseau `back` ; un conteneur multi-réseaux sert de passerelle applicative (comme
l'API). C'est pourquoi adminer est derrière un profil et ne doit pas tourner en permanence.

### B4 — variables obligatoires

`REGISTRY= docker compose -f compose.yml -f compose.prod.yml config` →
`required variable REGISTRY is missing a value: REGISTRY doit être défini`.

### B2 et B5 (non réalisés, pistes)

- B2 : `mkcert api.localhost adminer.localhost`, fichier de configuration dynamique Traefik (`tls.certificates`)
  monté en lecture seule, entrypoint `websecure` sur 443 et redirection
  `TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO=websecure`.
- B5 : `include:` pour découper (ex. `infra/compose.data.yml` pour db/redis maintenu par l'équipe plateforme,
  inclus par le compose applicatif) ; `docker compose publish` pour pousser le fichier compose comme artefact OCI dans le registre.

## Points d'attention

- Le socket Docker est monté (en lecture seule) dans Traefik : quiconque compromet Traefik contrôle le
  daemon. En prod, intercaler un `docker-socket-proxy` qui n'autorise que la lecture des conteneurs.
- `secrets/db_password.txt` est en mode 644 : les conteneurs non-root (node, worker, postgres) doivent
  pouvoir le lire, et Compose (hors Swarm) ne gère pas `uid`/`mode` pour les secrets fichiers.
- Dev et prod utilisent le même nom d'image (`localhost:5000/shopapi:${VERSION}`) : un `make up` reconstruit
  localement ce tag. C'est sans effet sur la prod (`pull_policy: always`), mais `make release` doit être
  lancé depuis un état propre (CI).
