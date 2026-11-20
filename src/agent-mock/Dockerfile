# syntax=docker/dockerfile:1
# Agente de IA simulado: agent.inbound → agent.outbound (ADR-008; docs/10, seção 3.3). Contexto de build: src/.
# Mantenha igual ao .ruby-version (docs/10, seção 4).
ARG RUBY_VERSION=4.0.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    LANG="C.UTF-8"

COPY contracts /contracts
COPY agent-mock/Gemfile agent-mock/Gemfile.lock agent-mock/.ruby-version ./
RUN bundle install --jobs 4

COPY agent-mock .

CMD ["bundle", "exec", "karafka", "server"]
