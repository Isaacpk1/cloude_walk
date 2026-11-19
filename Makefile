# Comandos do dia a dia (ADR-011). Detalhes em docs/10-organizacao-do-repositorio.md.
COMPOSE := docker compose
PLATFORM := $(COMPOSE) run --rm web

.PHONY: help up down logs seed reset test lint security check

help: ## Lista os comandos
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

.env:
	cp .env.example .env

up: .env ## Sobe o ambiente e prepara o banco
	$(COMPOSE) up -d --build --wait

down: ## Para o ambiente
	$(COMPOSE) down

logs: ## Acompanha os logs
	$(COMPOSE) logs -f

seed: ## Carrega os dados sintéticos (SEED e CUSTOMERS_PER_BRAND no .env)
	$(PLATFORM) bin/rails db:seed

reset: ## Recria o banco e carrega o seed
	$(PLATFORM) bin/rails db:reset

test: ## Roda o rspec da plataforma e dos contratos
	$(PLATFORM) sh -c "RAILS_ENV=test bin/rails db:prepare && bundle exec rspec"
	docker run --rm -v $(CURDIR)/src/contracts:/contracts -w /contracts ruby:3.3.6-slim sh -c "bundle install --quiet && bundle exec rspec"

lint: ## Roda o rubocop
	$(PLATFORM) bundle exec rubocop

security: ## Roda o brakeman
	$(PLATFORM) bundle exec brakeman -q --no-pager

check: test lint security ## Tudo que precisa passar antes do PR
