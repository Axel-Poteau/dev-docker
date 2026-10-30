# GestStock — raccourcis d'exploitation (« make help »). Détails : RUNBOOK.md
SHELL := /usr/bin/env bash
PROD_FILES := compose.yml:compose.prod.yml:compose.hardened.yml
.DEFAULT_GOAL := help
.PHONY: help init up down ps logs test rapport audit backup restore migrate obs-up obs-down prod-up ci deploy rollback rotate-db-password

help: ## Liste des commandes
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: .env secrets/db_password.txt secrets/db_root_password.txt secrets/db_exporter_password.txt secrets/grafana_admin_password.txt ## Prépare .env et les secrets (une fois)
.env:
	cp .env.example .env
secrets/%.txt:
	@umask 077; mkdir -p secrets; openssl rand -hex 24 > $@; chmod 644 $@; echo "secret généré : $@"

up: init ## Dev : build + stack + Mailpit, attend healthy
	docker compose up -d --build --wait && docker compose ps
down: ## Arrête la stack (volumes conservés)
	docker compose down
ps: ## État des services
	docker compose ps
logs: ## Suit les logs (S=app pour un service)
	docker compose logs -f $(S)
test: ## Smoke test de bout en bout
	./scripts/smoke-test.sh
rapport: ## Lance le rapport quotidien maintenant (mail → Mailpit en dev)
	docker compose exec cron php bin/rapport.php
audit: ## Audit de durcissement des conteneurs GestStock
	./scripts/audit.sh --filter label=com.docker.compose.project=geststock
backup: ## Sauvegarde base + photos dans backups/<horodatage>
	./scripts/backup.sh
restore: ## Restaure : make restore B=backups/<horodatage>
	@test -n "$(B)" || { echo "usage: make restore B=backups/<horodatage>"; exit 2; }
	./scripts/restore.sh $(B)
migrate: ## Reprise legacy : make migrate DUMP=… UPLOADS=…
	./scripts/migrate-legacy.sh $(DUMP) $(UPLOADS)
obs-up: init ## Démarre l'observabilité (Grafana http://127.0.0.1:3001)
	docker compose -f observability/compose.yml up -d --wait
obs-down: ## Arrête l'observabilité
	docker compose -f observability/compose.yml down
prod-up: init ## Prod durcie (VERSION=sha-… SMTP_HOST=…)
	COMPOSE_FILE=$(PROD_FILES) docker compose up -d --wait
ci: ## Pipeline local (EVENT=pr|main)
	./ci-local.sh
deploy: ## Rolling update : make deploy VERSION=sha-…
	COMPOSE_FILE=$(PROD_FILES) VERSION=$(VERSION) ./deploy/rolling-update.sh
rollback: deploy ## Retour arrière : make rollback VERSION=<tag précédent>
rotate-db-password: ## Rotation du mot de passe applicatif MariaDB (cf. RUNBOOK.md)
	./scripts/rotate-db-password.sh
