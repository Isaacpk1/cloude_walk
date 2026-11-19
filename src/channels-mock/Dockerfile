# syntax=docker/dockerfile:1
# Provedores simulados e simulador do cliente (RF-04, ADR-012). Contexto de build: src/.
# Mantenha igual ao .ruby-version (docs/10, seção 4).
ARG RUBY_VERSION=4.0.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    LANG="C.UTF-8"

COPY contracts /contracts
COPY channels-mock/Gemfile channels-mock/Gemfile.lock ./
RUN bundle install --jobs 4

COPY channels-mock .

EXPOSE 4000
CMD ["bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "4000"]
