# geststock-docker

GestStock (inventaire PHP, installé à la main sur Debian 10 depuis 2017) livré en stack conteneurisée :
PHP 8.3 + Apache non-root, MariaDB 11.4, Traefik, rapport planifié (supercronic), sauvegardes,
observabilité, CI/CD avec déploiement sans interruption.

```bash
make init && make up && make test        # dev : http://geststock.localhost:8090
make help                                # toutes les commandes
```

| Dossier / fichier | Contenu |
|---|---|
| `app/` | code GestStock. Seuls changements : `lib/config.php` (variables d'environnement + `DB_PASS_FILE`), `app_log` en JSON sur stderr, en-tête UTF-8 du mail de `bin/rapport.php` |
| `Dockerfile`, `docker/` | image multi-stage (supercronic vérifié, `pdo_mysql` compilé à part, étape test), config PHP/Apache de prod |
| `compose*.yml` | base, dev, prod, durci, Mailpit, observabilité (cf. RUNBOOK §0) |
| `scripts/` | `smoke-test`, `migrate-legacy`, `backup`, `restore`, `rotate-db-password`, `setup-exporter`, `audit` (TP08), `release-gate` (TP03) |
| `deploy/` | `rolling-update.sh`, `measure-downtime.sh` |
| `observability/` | Loki, Alloy, Prometheus, cAdvisor, Grafana (sources et tableau de bord provisionnés) |
| `legacy-sample/` | simulateur du serveur legacy (dump MariaDB 10.3 + photos) |
| `ci-local.sh`, `.github/workflows/ci.yml` | pipeline |
| [`RUNBOOK.md`](RUNBOOK.md) | démarrer, mettre à jour, revenir en arrière, sauvegarder/restaurer, diagnostiquer, faire tourner les secrets |

Aucun mot de passe n'est versionné : `secrets/*.txt` et `.env` sont générés par `make init` et
gitignorés.
