# TP10 — Projet fil rouge : GestStock conteneurisé et industrialisé : rapport

Le dépôt livré est [`geststock-docker/`](geststock-docker). Son [`RUNBOOK.md`](geststock-docker/RUNBOOK.md)
est le livrable n°10. Les preuves d'exécution (`*.txt`) sont dans ce dossier.

## Livrables

| # | Livrable | Où | Preuve |
|---|---|---|---|
| 1 | Dockerfile multi-stage, `php:8.3.36-apache-bookworm`, non-root (`www-data`, port 8080), `HEALTHCHECK ?health`, labels OCI, PHP de prod, `.dockerignore` | [`Dockerfile`](geststock-docker/Dockerfile), [`docker/`](geststock-docker/docker) | image 180 Mo, `display_errors=Off`, upload 20M/25M ; [`release-gate.txt`](release-gate.txt) ACCEPTÉ |
| 2 | Logs sur stdout/stderr : `app_log` en JSON → `php://stderr`, Apache → `/proc/self/fd/{1,2}` | [`app/lib/db.php`](geststock-docker/app/lib/db.php), [`apache-geststock.conf`](geststock-docker/docker/apache-geststock.conf) | [`observabilite.txt`](observabilite.txt) |
| 3 | Config par `getenv()` + `DB_PASS_FILE` | [`app/lib/config.php`](geststock-docker/app/lib/config.php) | plus aucun mot de passe dans le code (`GestStock2017!` supprimé) |
| 4 | `compose.yml` / `.override` / `.prod`, MariaDB épinglé + volume + `schema.sql`, volume uploads, réseaux segmentés, healthchecks, `depends_on: service_healthy`, Traefik, limites, logs rotatifs | `compose*.yml` | [`prod-smoke.txt`](prod-smoke.txt) |
| 5 | Cron supercronic (même image), mail via Mailpit en dev (`SMTP_HOST`), testable à la demande | service `cron`, [`compose.mailpit.yml`](geststock-docker/compose.mailpit.yml) | [`cron-planificateur.txt`](cron-planificateur.txt) |
| 6 | Migration legacy, `backup.sh` / `restore.sh` testés, procédure | [`scripts/`](geststock-docker/scripts), RUNBOOK §4-5 | [`migration.txt`](migration.txt), [`backup-restore.txt`](backup-restore.txt), [`incident-restauration.txt`](incident-restauration.txt) |
| 7 | Observabilité : Loki (via Alloy), cAdvisor, Prometheus, Grafana ; bonus mysqld-exporter | [`observability/`](geststock-docker/observability), [`compose.observability.yml`](geststock-docker/compose.observability.yml) | [`observabilite.txt`](observabilite.txt) |
| 8 | `compose.hardened.yml`, `audit.sh` sans écart, release gate (scan + secrets) + signature | [`compose.hardened.yml`](geststock-docker/compose.hardened.yml) | [`audit-prod-hardened.txt`](audit-prod-hardened.txt) : **aucun écart sur 7 conteneurs** |
| 9 | CI : build → test (`php -l` + `curl` sur la stack démarrée) → gate → push → rolling | [`ci-local.sh`](geststock-docker/ci-local.sh), [`ci.yml`](geststock-docker/.github/workflows/ci.yml) | [`ci-main-959964c.txt`](ci-main-959964c.txt), [`ci-main-07adf76.txt`](ci-main-07adf76.txt) |
| 10 | RUNBOOK | [`RUNBOOK.md`](geststock-docker/RUNBOOK.md) | |

Le TP07 (observabilité) n'a pas été rendu. Le dossier [`observability/`](geststock-docker/observability)
fournit donc la stack minimale que GestStock rejoint.

## Contraintes métier : où et comment elles sont tenues

| Contrainte | Mise en œuvre |
|---|---|
| code modifié à la marge | 3 fichiers touchés : `config.php` (réécrit en `getenv`), `db.php` (`app_log` : format JSON, cible stderr), `rapport.php` (en-têtes MIME UTF-8 du mail : sans eux, les accents arrivaient en latin-1). `index.php` est **inchangé** : le drain du rolling update est une règle Apache, pas du PHP |
| photos et base migrées | `migrate-legacy.sh` : dump MariaDB 10.3 → 11.4, photos en `www-data`, contrôles (9/9 articles, toutes les photos référencées présentes, accents intacts) |
| rapport testable sans attendre 6 h | `make rapport` (à la demande) et `RAPPORT_SCHEDULE="* * * * *"`, qui teste **le planificateur lui-même** : mail reçu, `job succeeded`, `supercronic_successful_executions=1` |
| PHP 7.3 → 8.3 | le code tourne tel quel : `php -l` OK et **0** `Deprecated`/`Warning`/`Fatal` dans les logs après les smoke tests. PDO en `ERRMODE_EXCEPTION` et des fonctions simples rendent le saut sans douleur |
| zéro mot de passe dans git | `secrets/*.txt` et `.env` gitignorés, générés par `make init` ; en CI, secrets éphémères (`openssl rand`) ; rotation documentée |
| zéro root | app/cron `www-data`, MariaDB `999:999` (aucune capacité), Traefik `nobody`, proxy de socket `nobody:0`, Mailpit/exporter `nobody`. Vérifié par `ps` dans chaque conteneur |
| zéro interruption | rolling update avec drain : **0 échec sur 5 500 requêtes** ([`rolling-drain.txt`](rolling-drain.txt)) |

## Choix laissés à mon jugement

### Apache intégré (`php:8.3-apache`) plutôt que nginx + php-fpm

- **Fidélité au legacy.** L'alias `/uploads → /var/www/uploads` et le DocumentRoot `public/` se
  transposent tels quels dans un vhost. Avec nginx + fpm, il faudrait deux configurations à garder
  cohérentes (chemins de scripts identiques dans deux images).
- **Une seule image** pour le web et pour le cron. Une seule chose à construire, scanner, signer et
  déployer, avec un rolling update d'un seul service.
- **Mêmes garanties de sécurité.** `php_admin_flag engine off` sur `/uploads`, `lib/`, `bin/`, `sql/`
  non servis, non-root sur 8080, rootfs en lecture seule.
- **Le coût est acceptable à cette échelle.** mod_php en prefork consomme plus de mémoire par
  requête simultanée qu'un pool fpm. L'application est un petit outil interne (dizaines de
  requêtes/s), et 2 réplicas tiennent dans 256 Mo chacun. Si la charge l'exigeait, on passerait à
  nginx + fpm (cache statique, pool dimensionné à part), sans toucher au code.

### Cron : supercronic dans un conteneur dédié, avec la même image

| | supercronic (retenu) | ofelia (labels) | cron de l'hôte + `compose run` |
|---|---|---|---|
| simplicité | un service, une ligne de crontab générée depuis `RAPPORT_SCHEDULE` | un service de plus + labels | hors du dépôt, à provisionner sur chaque serveur |
| sécurité | non-root, read-only, aucune capacité, **pas de socket Docker** | **socket Docker** (lancer des conteneurs = root sur l'hôte) | il faut un utilisateur qui pilote docker sur l'hôte |
| observabilité | logs du job sur stdout (Loki), `/metrics` Prometheus (succès/échecs), `/health` | logs corrects, pas de métriques natives | logs dans syslog de l'hôte, rien côté stack |
| portabilité | part avec la stack (préprod, CI, autre serveur) | idem | non |

Le piège rencontré : l'image hérite de `STOPSIGNAL SIGWINCH` (arrêt gracieux d'Apache), que
supercronic ignore. Chaque arrêt du cron attendait donc 10 s puis finissait en SIGKILL (exit 137),
même au milieu d'un rapport. D'où `stop_signal: SIGTERM` + `stop_grace_period: 60s` : arrêt en 0,4 s.

### Volume des uploads en prod : volume local nommé, sauvegardé, prêt pour NFS

- **Volume local nommé (retenu).** Un seul hôte de prod (le besoin du legacy), deux réplicas sur cet
  hôte qui partagent le volume, performances locales. Le risque, c'est la perte du disque, couverte
  par `backup.sh` (tar des photos dans la même sauvegarde que la base, donc cohérente) **avec une
  copie hors serveur**.
- **NFS.** Nécessaire dès qu'il y a plusieurs hôtes. C'est une modification de déclaration, sans
  toucher au code :

  ```yaml
  volumes:
    uploads:
      driver_opts: {type: nfs, o: "addr=nas.interne,nfsvers=4,rw", device: ":/geststock/uploads"}
  ```

  Il faut alors veiller à l'uid 33 côté export et aux verrous NFS (aucun ici : écriture de fichiers
  au nom unique).
- **S3 via proxy (s3fs, rclone mount).** C'est un montage FUSE dans le conteneur, qui demande
  `SYS_ADMIN` et `/dev/fuse`, ce qui contredit le durcissement. Écrire nativement en S3 demanderait de
  réécrire `move_uploaded_file` et l'affichage, ce qui sort du « modifié à la marge ». À envisager
  lors d'une vraie refonte.

## Ce que les tests ont révélé (et corrigé)

| Problème rencontré | Correction |
|---|---|
| proxy de socket en `nobody` : pidfile impossible dans `/run` (dev, sans le durcissement) | tmpfs `/run` et `/tmp` dans la base |
| smoke test faussement rouge : `grep -q` + `pipefail` → SIGPIPE sur `docker compose logs` | capture dans une variable avant `grep -q` |
| Mailpit non durci : 5 écarts à l'audit | read-only, `cap_drop`, nnp, limites |
| cAdvisor ne voit aucun conteneur : cgroupns privé, puis *containerd image store* de Docker Desktop (`failed to identify the read-write layer ID`) | `cgroup: host`, fabrique docker neutralisée, cgroups bruts `/docker/<id>`. Sur un serveur Linux en overlay2, on retrouve les labels compose |
| Alloy : `mkdir /var/lib/alloy/data: permission denied` | utilisateur `alloy` (473) + `group_add: ["0"]` pour la socket |
| logs Apache avec l'IP de Traefik : `RemoteIPTrustedProxy` refuse une IP client privée | `RemoteIPInternalProxy` |
| CI : le Traefik d'une stack de test aurait routé vers les conteneurs de prod (même règle `Host`) | `providers.docker.constraints` sur le projet compose |
| CI : 404 juste après `up --wait` (Traefik healthy ≠ routes chargées) | le smoke test attend la route (prête en 1 s) |
| CI : app unhealthy, volume db d'un run précédent initialisé avec d'autres secrets | la CI repart d'un projet vierge (`down -v` avant `up`) |
| rolling : **63 échecs** / 5 070 ([`rolling.txt`](rolling.txt)) : Traefik route encore vers l'Apache en arrêt | **drain** : `touch /tmp/drain` → règle `mod_rewrite` qui fait répondre `?health` en 503 → healthcheck actif Traefik (2 s) → arrêt. Résultat : **0 / 5 500** |
| rotation du mot de passe BDD : 70 échecs (fenêtre de démontage du conteneur `ops`) | `exec` dans `db` : 12 échecs. Le zéro strict passe par deux utilisateurs A/B (RUNBOOK §8) |

## Incident réel pendant le TP

En déboguant la CI, j'ai lancé `docker compose down -v` dans un nouveau shell, sans les variables du
projet CI (`COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`). La commande a donc visé le projet `geststock`
lui-même : **conteneurs et volumes supprimés** (base reprise du legacy + photos). Le pipeline suivant
a redéployé sur des volumes vides, puis `restore.sh` a restauré la sauvegarde de 10:49 en 20 s
([`incident-restauration.txt`](incident-restauration.txt)). Les seules pertes sont des articles de
smoke test postérieurs : c'est le **RPO**.

Leçons, reportées dans le RUNBOOK :

- toujours vérifier le projet visé avant un `down -v` ;
- tester les restaurations régulièrement ;
- une sauvegarde doit exister **avant** toute opération risquée : `migrate-legacy.sh` en fait une
  automatiquement.

## Résultats chiffrés

| Mesure | Valeur |
|---|---|
| image | 180 Mo (`php:8.3.36-apache-bookworm` + msmtp + supercronic) ; trivy : aucune CVE HIGH/CRITICAL corrigeable |
| pipeline `main` complet (lint → intégration → gate → signature → rolling) | 94 à 115 s |
| rolling update / redémarrage progressif | ~45 s, **0 échec** sur 5 500 requêtes |
| restauration complète | 22 s |
| reprise legacy | 27 s (dont sauvegarde de sécurité) |
| audit de durcissement | 0 écart sur 7 conteneurs (1 exception documentée : socket du proxy filtré) |
