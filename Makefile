# Comandos do dia a dia (ADR-011). Detalhes em docs/10-organizacao-do-repositorio.md.
COMPOSE := docker compose
PLATFORM := $(COMPOSE) run --rm web
# Mesma versão do CI (setup-ruby lê o .ruby-version de cada serviço).
CONTRACTS_RUBY := $(shell sed 's/^ruby-//' src/contracts/.ruby-version)

.PHONY: help up down logs seed reset test lint security check topics eval bench validate-operation

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

CENARIO ?= corrida-3s
BRAND ?= infinitepay
eval: ## Roda um eval e grava o resultado (CENARIO=corrida-3s BRAND=infinitepay; ADR-023)
	$(PLATFORM) env BRAND=$(BRAND) bin/rails "evals:run[$(CENARIO)]"

reset: ## Recria o banco, carrega o seed e reinicia o channels-mock (o estado dele fica em memória, ADR-021)
	$(PLATFORM) bin/rails db:reset
	$(COMPOSE) restart channels-mock

test: ## Roda o rspec da plataforma, dos contratos, do broker, do agente mock e dos canais simulados
	$(PLATFORM) -v $(CURDIR)/bench:/bench:ro sh -c "RAILS_ENV=test bin/rails db:prepare && RAILS_ENV=test DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL=true bundle exec rspec"
	docker run --rm -v $(CURDIR)/src/contracts:/contracts -w /contracts ruby:$(CONTRACTS_RUBY)-slim sh -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential >/dev/null && bundle install --quiet && bundle exec rspec"
	$(COMPOSE) run --rm --no-deps broker bundle exec rspec
	$(COMPOSE) run --rm --no-deps agent-mock bundle exec rspec
	$(COMPOSE) run --rm --no-deps channels-mock bundle exec rspec

lint: ## Roda o rubocop
	$(PLATFORM) bundle exec rubocop
	$(COMPOSE) run --rm --no-deps broker bundle exec rubocop
	$(COMPOSE) run --rm --no-deps agent-mock bundle exec rubocop
	$(COMPOSE) run --rm --no-deps channels-mock bundle exec rubocop

security: ## Roda o brakeman
	$(PLATFORM) bundle exec brakeman -q --no-pager

topics: ## Lista os tópicos do Kafka e as mensagens de entrada, saída e DLQ do agente (blocos 03 e 04)
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --list
	@for t in helpdesk.agent.inbound.v1 helpdesk.agent.outbound.v1 helpdesk.agent.dlq.v1; do \
		echo "== $$t"; \
		$(COMPOSE) exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 \
			--topic $$t --from-beginning --timeout-ms 5000 \
			--property print.key=true --property print.headers=true || true; \
	done

# Experimento E1/E5 (docs/05, seção 2; bloco 19). O k6 roda num contêiner na rede do Compose, contra o `web`.
# PROFILE=smoke|reference|capacity, MODE=independent|burst, RUNS=3 execuções por cenário. Veja bench/README.md.
PROFILE ?= smoke
MODE ?= independent
RUNS ?= 3
SEED ?= 42
bench: ## Roda o experimento de carga e reconcilia o resultado (PROFILE=smoke|reference|capacity MODE=independent|burst RUNS=3)
	@mkdir -p bench/results/$(shell date +%F)-$(PROFILE)-$(MODE)
	@for i in $$(seq 1 $(RUNS)); do \
	  run=$$(date +%Y%m%d%H%M%S)-$$i; dir=bench/results/$(shell date +%F)-$(PROFILE)-$(MODE); \
	  echo "== execução $$i de $(RUNS) ($$run) =="; \
	  docker run --rm --user $$(id -u):$$(id -g) --network $$($(COMPOSE) ps -q web | xargs docker inspect -f '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}}{{end}}') \
	    -v $$(pwd)/bench/k6:/scripts:ro -v $$(pwd)/$$dir:/results \
	    -e PLATFORM_URL=http://web:3000 -e PROFILE=$(PROFILE) -e MODE=$(MODE) -e SEED=$(SEED) -e RUN_ID=$$run \
	    grafana/k6:0.54.0 run /scripts/chat_load.js || true; \
	  $(COMPOSE) run --rm -T -v $$(pwd)/bench:/bench:ro -v $$(pwd)/$$dir:/results web bin/rails runner /bench/analysis/reconcile.rb $$run /results/$$run-k6.json > $$dir/$$run-db.json || true; \
	  cat $$dir/$$run-db.json; \
	done

validate-operation: ## Evidências de E2/E3/E4/E6 em banco de teste separado (blocos 17 e 18)
	@mkdir -p bench/results/operation
	$(PLATFORM) -v $(CURDIR)/bench:/bench:ro -v $(CURDIR)/bench/results/operation:/results -e RAILS_ENV=test -e TEST_ENV_NUMBER=_operation -e VALIDATION_REVISION=$(shell git rev-parse HEAD) -e DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL=true sh -c "bin/rails db:prepare && ruby /bench/validation/run.rb /results"

check: test lint security ## Tudo que precisa passar antes do PR
