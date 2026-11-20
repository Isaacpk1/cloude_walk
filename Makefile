# Comandos do dia a dia (ADR-011). Detalhes em docs/10-organizacao-do-repositorio.md.
COMPOSE := docker compose
PLATFORM := $(COMPOSE) run --rm web
# Mesma versão do CI (setup-ruby lê o .ruby-version de cada serviço).
CONTRACTS_RUBY := $(shell sed 's/^ruby-//' src/contracts/.ruby-version)

.PHONY: help up down logs seed reset test lint security check topics

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

test: ## Roda o rspec da plataforma, dos contratos, do broker e dos canais simulados
	$(PLATFORM) sh -c "RAILS_ENV=test bin/rails db:prepare && bundle exec rspec"
	docker run --rm -v $(CURDIR)/src/contracts:/contracts -w /contracts ruby:$(CONTRACTS_RUBY)-slim sh -c "bundle install --quiet && bundle exec rspec"
	$(COMPOSE) run --rm --no-deps broker bundle exec rspec
	$(COMPOSE) run --rm --no-deps channels-mock bundle exec rspec

lint: ## Roda o rubocop
	$(PLATFORM) bundle exec rubocop
	$(COMPOSE) run --rm --no-deps broker bundle exec rubocop
	$(COMPOSE) run --rm --no-deps channels-mock bundle exec rubocop

security: ## Roda o brakeman
	$(PLATFORM) bundle exec brakeman -q --no-pager

topics: ## Lista os tópicos do Kafka e as mensagens de helpdesk.agent.inbound.v1 (bloco 03)
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --list
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 \
		--topic helpdesk.agent.inbound.v1 --from-beginning --timeout-ms 5000 \
		--property print.key=true --property print.headers=true || true

check: test lint security ## Tudo que precisa passar antes do PR
