# syntax=docker/dockerfile:1
# Broker de webhooks: plataforma → Kafka (ADR-007; docs/10, seção 3.2). Contexto de build: src/.
ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    LANG="C.UTF-8"

COPY contracts /contracts
COPY broker/Gemfile broker/Gemfile.lock ./
RUN bundle install --jobs 4

COPY broker .

EXPOSE 4100
CMD ["bundle", "exec", "puma"]
