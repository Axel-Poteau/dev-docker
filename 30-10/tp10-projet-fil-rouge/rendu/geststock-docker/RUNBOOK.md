# GestStock — RUNBOOK d'exploitation

## 0. Vue d'ensemble

```
                 :80 (HTTP_PORT)
Internet ──▶ proxy (Traefik, nobody) ──front──▶ app ×2 (Apache+PHP 8.3, www-data) ──back (internal)──▶ db (MariaDB 11.4, uid 999)
                │ socket (internal)                  │ volume uploads ◀── photos            ▲         volume dbdata
                ▼                                    │                                      │
        socket-proxy (API Docker GET filtrée)        cron (supercronic, même image) ──mail──▶ relais SMTP (Mailpit en dev)
                                                     │
              observability : Alloy → Loki, Prometheus ← cAdvisor / mysqld-exporter / supercronic / Traefik, Grafana
```

| Fichier compose | Rôle |
|---|---|
| `compose.yml` | base : services, réseaux, volumes, secrets, healthchecks |
| `compose.override.yml` | dev : code monté, `display_errors=On`, dashboard Traefik |
| `compose.mailpit.yml` | faux relais SMTP (dev, CI, préprod) |
| `compose.prod.yml` | prod : images du registre, 2 réplicas, limites, `SMTP_HOST` obligatoire |
| `compose.hardened.yml` | prod : read-only, `cap_drop: ALL`, `no-new-privileges`, PID/CPU/mémoire |
| `compose.observability.yml` | rattachement à `observability/compose.yml` (exporter MariaDB, métriques) |

La liste des fichiers vient de `COMPOSE_FILE`. En dev elle est dans `.env`. En prod :
`COMPOSE_FILE=compose.yml:compose.prod.yml:compose.hardened.yml[:compose.observability.yml]`.

## 1. Démarrer

**Dev :**

```bash
make init     # .env + secrets/*.txt aléatoires (gitignorés)
make up       # build + stack + Mailpit, attend healthy
make test     # smoke test de bout en bout
```

URL : `http://geststock.localhost:8090`, Mailpit sur `http://mail.localhost:8090`.

**Prod.** Prérequis sur le serveur, **jamais dans git** :

- `secrets/db_password.txt`, `db_root_password.txt` et `db_exporter_password.txt`, en mode 644 dans
  un dossier 700 (`SECRETS_DIR` si ailleurs) ;
- `.env` avec `REGISTRY`, `VERSION`, `SMTP_HOST` (relais de l'entreprise) et `HTTP_PORT`.

```bash
export COMPOSE_FILE=compose.yml:compose.prod.yml:compose.hardened.yml
docker compose up -d --wait && make test
make audit                                   # doit finir sur « aucun écart »
```

Premier démarrage : MariaDB initialise la base à partir de `app/sql/schema.sql`, uniquement si le
volume est vide.

## 2. Mettre à jour

Le chemin normal passe par la CI (`.github/workflows/ci.yml`, ou `./ci-local.sh` en local) :

- **PR** : lint → `php -l` → build → stack éphémère → smoke + audit ;
- **main** : + gate (trivy) → push `sha-<sha>` → signature → `deploy/rolling-update.sh`.

À la main :

```bash
VERSION=sha-<sha> ./deploy/rolling-update.sh      # signature à vérifier avant (cosign verify)
```

Pour chaque réplica, le script :

1. ajoute un réplica neuf et attend qu'il soit `healthy` (`?health` = base joignable) ;
2. **draine** l'ancien : `touch /tmp/drain`, `?health` passe en 503 et Traefik le retire du pool
   en ≤ 2 s ;
3. l'arrête proprement (SIGWINCH : Apache termine les requêtes en cours).

Mesuré : **0 échec sur 5 500 requêtes** (`rolling-drain.txt`).

**Refus « labels Traefik modifiés » (code 3).** Ancienne et nouvelle version déclarent le service
différemment, et Traefik le supprimerait pendant toute la cohabitation (404). Ce type de changement
se déploie dans une fenêtre annoncée, avec `ALLOW_LABEL_CHANGE=1`.

**Rotation de secret ou redémarrage sans nouvelle version :**
`FORCE=1 VERSION=<tag courant> ./deploy/rolling-update.sh`.

## 3. Revenir en arrière

```bash
VERSION=<tag précédent> ./deploy/rolling-update.sh     # même mécanique, ~45 s
```

- Les tags `sha-*` sont immuables et signés. L'image précédente est encore dans le registre et en
  cache sur l'hôte.
- Revenir **avant `sha-07adf76`** franchit un changement de labels : le script refuse
  (`rollback-garde-fou.txt`). Il faut `ALLOW_LABEL_CHANGE=1` et accepter quelques secondes de 404.
- **Schéma de base** : toute migration doit rester compatible avec la version N-1 (expand / contract),
  sinon le rollback devient une restauration (§4).

## 4. Sauvegarder / restaurer

```bash
./scripts/backup.sh                  # backups/<horodatage>/ : db.sql.gz, uploads.tar.gz, meta.txt, SHA256SUMS
./scripts/restore.sh backups/<horodatage>        # vérifie les sommes, arrête app+cron, restaure, contrôle, redémarre
```

**Sauvegarde :**

- `mariadb-dump --single-transaction` se fait **à chaud**, sans arrêt ni verrou (InnoDB) ;
- rotation `KEEP=7` : le legacy avait rempli son disque faute de rotation.

**Planification** (cron de l'hôte, ou un job du même type que le rapport) :
`0 2 * * * cd /srv/geststock && ./scripts/backup.sh && rclone copy backups/ s3:geststock-backups`.
Une sauvegarde qui reste sur le même disque n'en est pas une : il faut **toujours une copie hors du
serveur**.

**Restauration :**

- une sauvegarde altérée est refusée (`sommes de contrôle invalides`) ;
- **RTO mesuré : 22 s** (`backup-restore.txt`) ;
- **RPO** = intervalle entre deux sauvegardes. On l'a vu en vrai le 30/10
  (`incident-restauration.txt`) : un `docker compose down -v` lancé sur le mauvais projet a supprimé
  la base, et tout ce qui datait de la sauvegarde précédente a été récupéré en 20 s.

**Tester la restauration** chaque mois sur une stack jetable, `COMPOSE_PROJECT_NAME=geststock-drill`.

> ⚠️ `down -v` supprime les volumes. Il ne faut **jamais** le lancer sans avoir vérifié le projet
> visé (`docker compose ls`, `COMPOSE_PROJECT_NAME`).

## 5. Reprise des données legacy (jour J)

1. Sur l'ancien serveur, couper l'écriture (Apache stop), puis :
   - `mysqldump --single-transaction geststock > geststock-dump.sql` ;
   - `tar -C /var/www/html/uploads -czf uploads.tar.gz .` ;
   - `sha256sum * > SHA256SUMS`.
2. Copier ces fichiers vers le nouveau serveur, puis lancer
   `./scripts/migrate-legacy.sh geststock-dump.sql uploads.tar.gz`.
3. Le script :
   - vérifie les sommes ;
   - fait une sauvegarde de sécurité ;
   - importe le dump (MariaDB 10.3 → 11.4 ; `MARIADB_AUTO_UPGRADE` met à jour les tables système) ;
   - copie les photos en `www-data` ;
   - contrôle le nombre d'articles et la présence de chaque photo référencée.
4. Basculer le DNS, puis garder l'ancien serveur éteint mais intact une semaine.

Répétition générale : `legacy-sample/simulate-legacy.sh` fabrique un dump MariaDB 10.3 réaliste
(`migration.txt`).

## 6. Rapport quotidien

| Action | Commande |
|---|---|
| horaire | `RAPPORT_SCHEDULE` (défaut `0 6 * * *`, fuseau Europe/Paris), exécuté par supercronic dans le service `cron` |
| **à la demande** | `make rapport` = `docker compose exec cron php bin/rapport.php` (le mail part aussi) |
| tester le planificateur réel | `RAPPORT_SCHEDULE="* * * * *" docker compose up -d cron`, attendre une minute, puis remettre (`cron-planificateur.txt`) |
| surveiller | métriques `supercronic_successful_executions` / `supercronic_failed_executions` (Prometheus), logs `{service="cron"}` dans Loki |

## 7. Diagnostiquer

| Où | Quoi |
|---|---|
| `docker compose ps` | état et santé (`healthy` / `unhealthy`) |
| `docker compose logs -f app` | accès Apache (IP client réelle), erreurs PHP, `app_log` JSON (`{"level":…,"msg":…}`) |
| Grafana `http://127.0.0.1:3001` (admin / `secrets/grafana_admin_password.txt`) | tableau « GestStock » : mémoire/CPU, MariaDB, HTTP par code, rapport, logs |
| Loki | `{project="geststock", service="app", level="error"}`, `{service="cron"} \|= "job failed"` |
| Prometheus | `mysql_up`, `rate(traefik_service_requests_total{code=~"5.."}[5m])`, `container_memory_working_set_bytes` |
| `make audit` | régression de durcissement |

Symptômes fréquents :

| Symptôme | Cause probable | Action |
|---|---|---|
| 404 sur tout le site | aucun réplica healthy, ou labels Traefik en conflit (`Service defined multiple times`) | `docker compose ps`, `docker compose logs proxy` |
| `?health` → `DB KO` | MariaDB arrêtée, ou mauvais mot de passe (secret modifié sans `ALTER USER`) | `docker compose logs db`, §8 |
| photos en 403/404 | volume `uploads` non monté, ou mauvais propriétaire | `docker compose exec app ls -l /var/www/uploads` (doit être `www-data`) |
| pas de mail | `SMTP_HOST` faux, ou relais injoignable (réseau `mail`) | `docker compose exec cron php bin/rapport.php` puis logs du relais |
| `cron` qui met 10 s à s'arrêter | `stop_signal` retiré (l'image hérite de SIGWINCH, que supercronic ignore) | garder `stop_signal: SIGTERM` |

## 8. Rotation des secrets

| Secret | Procédure | Interruption |
|---|---|---|
| mot de passe applicatif MariaDB | `make rotate-db-password` : `ALTER USER`, puis réécriture **en place** du fichier (même inode, le bind mount le voit sans redémarrage) | 12 échecs sur 1 390 requêtes (10 × 503, 2 timeouts) ; 70 avec la première version, qui utilisait un conteneur jetable (`rotation-secret.txt`). Pour zéro : deux utilisateurs A/B, bascule de `DB_USER` par `FORCE=1 rolling-update.sh`, puis suppression de l'ancien |
| root MariaDB | `ALTER USER root…` via `docker compose exec db`, puis réécrire `db_root_password.txt` en place | aucune (non utilisé par l'application) |
| exporter | régénérer `db_exporter_password.txt`, puis `./scripts/setup-exporter.sh` et `docker compose restart mysqld-exporter` | métriques MariaDB seulement |
| Grafana admin | réécrire le fichier, puis `grafana-cli admin reset-admin-password` | aucune |
| clé SSH de déploiement, jeton registre | régénérer dans les secrets d'environnement de la CI ; retirer l'ancienne clé de `authorized_keys` | aucune |

Ne **jamais** remplacer un secret par `mv` : c'est un nouvel inode, que les conteneurs ne verront
qu'après recréation.
