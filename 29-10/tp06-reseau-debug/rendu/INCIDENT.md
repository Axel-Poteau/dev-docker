# Rapport d'incident — préprod Shop SAS

**Heure de début** : 16:39 (diagnostic) · **Heure de résolution** : 16:43 (catalogue servi), 16:45 (compose durci, tout `healthy`) · **Impact** : préprod indisponible

Livrables : [`compose.yml`](compose.yml), [`nginx/default.conf`](nginx/default.conf) (corrections repérées `[Ax]`),
[`secrets.sh`](secrets.sh), [`smoke-test.sh`](smoke-test.sh). Transcripts : `partie1-rappels.txt`, `diag-01.txt` → `diag-17-final.txt`, `verif-corrections.txt`.

## Chronologie du diagnostic

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 16:39:19 | `curl localhost:8081` : connexion refusée | `docker compose config -q` → `can't set container_name and api as container name must be unique` | compose invalide, rien n'est démarré | confirmé, A1 (diag-01) |
| 16:39:30 | build impossible | `path ".../tp04-compose-entreprise/solution/apps/shopapi" not found` ; `ls ../../tp04-compose-entreprise` | contexte de build inexistant | confirmé, A2 → `rendu/` (diag-02/03) |
| 16:39:58 | front `Created`, jamais démarré | erreur runc `Are you trying to mount a directory onto a file` | dossier `./nginx` monté sur le fichier `default.conf` | confirmé, A3 |
| 16:40:07 | api `Exited (1)` | `logs api` : `Cannot find module '/app/server.js'` ; `ls /app/src` ; `image inspect` (`CMD node src/server.js`) | mauvaise commande | confirmé, A4 (diag-04) |
| 16:40:09 | db `healthy` mais… | `pg_isready -U postgres` → rc 0 ; `psql -U postgres` → `role "postgres" does not exist` | healthcheck qui ne teste pas le bon rôle | confirmé, A12 |
| 16:40:30 | front `Up`, port 8081 injoignable | `docker port` vide, `Ports {"80/tcp":[]}` ; `network inspect` → `internal=true` | réseau publié déclaré `internal` | confirmé, A8 (diag-05) |
| 16:41:01 | 52 *empty reply* puis `/health` OK | `curl -v` 10 s plus tard → 200 | course au démarrage du port-forward Docker Desktop | infirmé (pas une anomalie) |
| 16:41:11 | `nslookup api` → NXDOMAIN alors que front et api sont sur `incident_public` | `inspect … DNSNames` : `["incident-api-1", id]`, **pas d'alias `api`** | `up` a recréé le réseau et reconnecté les conteneurs existants **sans leurs alias de service** (Compose 2.39.4) | confirmé ; `up --force-recreate` rétablit l'alias (diag-08/09) |
| 16:41:41 | 502 | log nginx : `upstream: "http://127.0.0.1:3000"` | `localhost` = le conteneur nginx | confirmé, A9 |
| 16:41:54 | 502 vers `172.28.0.2:3000` | `env` → `PORT=8080` ; `ss -tlnp` (netshoot, `--network container:api`) → `*:8080` | port API ≠ port attendu par nginx | confirmé, A5 (diag-06/10) |
| 16:42:04 | 500 | log pino : `getaddrinfo ENOTFOUND databse` | faute de frappe | confirmé, A6 |
| 16:42:23 | `getent hosts db` vide | `network inspect incident_backend` → seul `incident-db-1` | api absente de `backend` | confirmé, A7 ; puis même perte d'alias pour `db` (diag-12/13) |
| 16:43:08 | `/ready` 503 | `Reached the max retries` puis, une fois sur `backend`, `NOAUTH Authentication required` ; `redis-cli` en `--network host` → `NOAUTH` | Redis en `network_mode: host` (hors DNS) + mot de passe absent de l'URL | confirmé, A10 + A11 (diag-11/14) |
| 16:43:26 | **200, `X-Cache: MISS` puis `HIT`** | `curl -i` ×2 | — | service rétabli |
| 16:43:50 | api `healthy` pendant l'arrêt de la base | `stop db` ; `State.Health` = healthy | healthcheck de l'image sur `/health` (liveness) | confirmé, A13 (diag-15) |
| 16:44:28 | `--scale api=3` : api-3 reçoit **0** requête | comptage des logs par réplica | nginx résout `api` une seule fois au démarrage | confirmé, A9b (diag-16) |
| 16:45:34 | compose final : 5/5 `healthy`, smoke test OK | `up -d --wait` ; `./smoke-test.sh` | — | résolu (diag-17) |

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie |
|---|-------------------|----------|------------|----------|
| A1 | compose / api | `container_name: api` + `replicas: 2` : projet invalide | supprimé | config |
| A2 | compose / api, db | chemins `tp04…/solution/` inexistants (build + `init.sql`) | `tp04…/rendu/` | config |
| A3 | compose / front | dossier `./nginx` monté sur un fichier | `./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro` | stockage |
| A4 | compose / api | `command: node server.js` (code dans `src/`) | `["node", "src/server.js"]` (forme exec) | cycle de vie |
| A5 | compose / api | `PORT: 8080` alors que nginx vise 3000 | supprimé (3000, défaut de l'image) | config / réseau |
| A6 | compose / api | hôte `databse` | `db` | config |
| A7 | compose / api | api seulement sur `public` : ne joint ni db ni redis | + `backend` | réseau |
| A8 | compose / networks | `public` en `internal: true` (port publié inopérant), `backend` ouvert | `public` normal, `backend` interne | réseau / sécurité |
| A9 | default.conf | `proxy_pass http://localhost:3000` | `http://api:3000` | réseau |
| A9b | default.conf | adresse résolue une fois au démarrage : nouveau réplica jamais servi, IP périmée | `resolver 127.0.0.11 valid=10s` + variable, `proxy_next_upstream` | réseau |
| A10 | compose / redis | `network_mode: host` : hors réseau Docker, pas de DNS, port 6379 exposé sur l'hôte | réseau `backend` | réseau / sécurité |
| A11 | compose / api | `REDIS_URL` sans le mot de passe (`requirepass`) | mot de passe injecté depuis un secret | config |
| A12 | compose / db | `pg_isready -U postgres` (rôle inexistant, healthcheck trompeur) | `-U shop -d shop` | cycle de vie |
| A13 | image / api | healthcheck `/health` : `healthy` même base arrêtée | healthcheck compose sur `/ready` (DB + Redis) | cycle de vie |
| A14 | compose | front et redis sans healthcheck, `depends_on: api` sans condition → 502 au démarrage, jamais « tout healthy » | healthchecks + `condition: service_healthy` | cycle de vie |
| A15 | compose | mots de passe en clair (`shop:shop`, `r3dis`) | secrets fichiers (`POSTGRES_PASSWORD_FILE`, entrypoint qui construit les URL), `secrets.sh`, gitignorés | sécurité |
| A16 | compose | ni `restart`, ni rotation des logs | `unless-stopped`, json-file 10m×3 | cycle de vie / stockage |

**Piège rencontré pendant le diagnostic** (pas une anomalie du fichier) : changer la définition d'un réseau puis
`docker compose up -d` recrée le réseau et **reconnecte** les conteneurs inchangés sans leur alias de service :
`api` et `db` ne résolvaient plus (NXDOMAIN) alors que tout semblait connecté. Après une modification de réseau :
`docker compose up -d --force-recreate`, ou `down` puis `up`.

## Vérification des corrections (`verif-corrections.txt`)

- `--scale api=3` : 21 / 26 / 22 réponses par réplica (contre 0 pour api-3 avant A9b) ;
- recréation de l'API **sans** redémarrer nginx : 40 × 200 (502 en boucle avant) ;
- base arrêtée : api sort de `healthy` et le front renvoie 500 ; base relancée → tout `healthy`, smoke test OK.

## Pourquoi ça n'a pas été détecté avant ?

- Aucune validation automatique : `docker compose config -q` aurait refusé A1 immédiatement.
- Pas de test de bout en bout : seul un `curl /products` à travers le front détecte A5–A11.
- Les healthchecks présents **mentaient** (A12, A13) : `docker compose ps` affichait `healthy` sur une stack cassée.
- Modification poussée sans revue, juste avant un départ en congé.

## Actions de prévention

1. **CI sur le compose** : `docker compose config -q` + `up -d --wait` sur une stack éphémère + `smoke-test.sh`
   (catalogue, `X-Cache: HIT`, tout `healthy`) à chaque modification ; merge bloqué si rouge.
2. **Des healthchecks qui testent les dépendances** (`/ready`, `pg_isready` avec le vrai rôle, `redis-cli ping`
   authentifié) et `depends_on: condition: service_healthy` partout : `--wait` échoue au lieu de démarrer une stack cassée.
3. **Revue obligatoire** (CODEOWNERS sur `compose*.yml`, `nginx/`) + lint (`dclint`/règles maison : pas de
   `network_mode: host`, pas de `container_name` avec `replicas`, pas de mot de passe en clair).
4. En bonus : supervision (TP07) — une alerte « API down » aurait réveillé l'astreinte à 8h, pas à 9h12.

## Partie 1 — à retenir (`partie1-rappels.txt`)

- bridge par défaut : `ping node-b` → `bad address` (pas de DNS), le ping par IP passe ; résolveur = celui de l'hôte (`192.168.65.7`) ;
- réseau utilisateur : `nameserver 127.0.0.11` (DNS embarqué), résolution par nom et par alias (`--alias database`) ;
- `internal` : `Network unreachable` vers l'extérieur ; `none` : seulement `lo` ; `host` : interfaces de la VM Docker Desktop ;
- `container:` : netshoot voit les interfaces et sockets de `node-a` (même pile réseau) ;
- `--expose` : `docker port` vide, rien n'est publié ; `-p 18888:80` → règle `DNAT … --to-destination 172.17.0.5:80` dans la table nat ;
- Docker 28 refuse les noms d'un caractère (`--name a` → `Invalid container name`).
