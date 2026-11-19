# syntax=docker/dockerfile:1
# Imagem única da plataforma: web, worker, consumer e scheduler mudam só o comando (docs/10, seção 6).
# Pensada para rodar localmente com `make up` (RNF-29), em RAILS_ENV=development.
# Mantenha igual ao .ruby-version (docs/10, seção 4).
ARG RUBY_VERSION=4.0.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config postgresql-client curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    RAILS_ENV="development" \
    RAILS_LOG_TO_STDOUT="1"

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
