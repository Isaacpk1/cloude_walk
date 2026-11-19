# syntax=docker/dockerfile:1
# Imagem única da plataforma: web, worker, consumer e scheduler mudam só o comando (docs/10, seção 6).
# Pensada para rodar localmente com `make up` (RNF-29), em RAILS_ENV=development.
# Contexto de build: src/ (docker-compose.yml), para a gem local de contratos ficar em /contracts,
# o mesmo caminho relativo do Gemfile (gem "helpdesk_contracts", path: "../contracts").
ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config postgresql-client curl && \
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
