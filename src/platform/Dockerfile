# syntax=docker/dockerfile:1
# Imagem única da plataforma: web, worker, consumer e scheduler mudam só o comando (docs/10, seção 6).
# Pensada para rodar localmente com `make up` (RNF-29), em RAILS_ENV=development.
# Contexto de build: src/ (docker-compose.yml), para a gem local de contratos ficar em /contracts,
# o mesmo caminho relativo do Gemfile (gem "helpdesk_contracts", path: "../contracts").
ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /rails

# O cliente do Postgres precisa ser da mesma versão maior do servidor do Compose (postgres:16).
# O Debian da imagem traz o 15, e o pg_dump 15 se recusa a ler um servidor 16: o Rails roda o
# pg_dump depois de cada migration para atualizar o structure.sql. Por isso o cliente vem do
# repositório oficial do PostgreSQL (PGDG).
ARG PG_MAJOR=16
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config curl ca-certificates && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y postgresql-client-${PG_MAJOR} && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    RAILS_ENV="development" \
    RAILS_LOG_TO_STDOUT="1"

COPY contracts /contracts
COPY platform/Gemfile platform/Gemfile.lock ./
RUN bundle install --jobs 4

COPY platform .

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
