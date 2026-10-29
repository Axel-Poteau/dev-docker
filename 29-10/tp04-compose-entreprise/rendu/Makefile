# Outillage d'équipe Shop SAS — "make help"
SHELL := /usr/bin/env bash
COMPOSE      := docker compose
COMPOSE_PROD := docker compose -f compose.yml -f compose.prod.yml
GIT_SHA      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
export GIT_SHA

.DEFAULT_GOAL := help
.PHONY: help init up down ps logs tools release prod-config prod-up prod-down prod-test migrate test watch clean

help: ## Liste des commandes
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: .env secrets/db_password.txt apps/shop-worker/pip.conf ## Prépare .env, secret BDD et pip.conf (une seule fois)
.env:
	cp .env.example .env
secrets/db_password.txt:
	@mkdir -p secrets
	@openssl rand -hex 24 > $@ && chmod 644 $@ && echo "secret BDD généré dans $@"
apps/shop-worker/pip.conf:
	cp apps/shop-worker/pip.conf.example $@

up: init ## Démarre la stack de DEV (build + override) et attend qu'elle soit saine
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

down: ## Arrête la stack (les volumes sont conservés)
	$(COMPOSE) --profile tools down

ps: ## État des services
	$(COMPOSE) ps

logs: ## Suit les logs (S=api pour un seul service)
	$(COMPOSE) logs -f $(S)

tools: ## Lance adminer (http://adminer.localhost:<HTTP_PORT>)
	$(COMPOSE) --profile tools up -d --wait adminer

watch: init ## Dev avec "docker compose watch" (sync + restart, bonus B1)
	$(COMPOSE) -f compose.yml -f compose.override.yml -f compose.watch.yml watch

migrate: ## Applique une migration : make migrate M=002-add-sku.sql
	@test -n "$(M)" || { echo "usage: make migrate M=<fichier dans db/migrations>"; exit 2; }
	MIGRATION=$(M) $(COMPOSE) run --rm migrate

test: ## Smoke test de la stack de dev
	./smoke-test.sh

release: init ## Construit et pousse les images VERSION=x.y au registre
	$(COMPOSE) -f compose.yml build
	$(COMPOSE) -f compose.yml push api worker

prod-config: ## Affiche la configuration de prod résolue
	$(COMPOSE_PROD) config

prod-up: init ## Démarre la stack de PROD (images du registre)
	$(COMPOSE_PROD) up -d --wait
	$(COMPOSE_PROD) ps

prod-down: ## Arrête la stack de prod
	$(COMPOSE_PROD) down

prod-test: ## Smoke test de la stack de prod
	COMPOSE="$(COMPOSE_PROD)" ./smoke-test.sh

clean: ## Supprime conteneurs ET volumes (DESTRUCTIF : demande confirmation)
	@read -p "Supprimer les volumes pgdata/redisdata ? [y/N] " r && [[ $$r == y ]]
	$(COMPOSE) --profile tools --profile ops down -v
