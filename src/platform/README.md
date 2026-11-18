# Plataforma (Rails 8)

App principal do help desk. Daqui saem os processos `web`, `worker`, `consumer` e `scheduler` (ADR-017). A organização das pastas está em [docs/10](../../docs/10-organizacao-do-repositorio.md#31-srcplatform--a-plataforma-rails-8).

## Rodar localmente

```bash
export DATABASE_URL=postgres://helpdesk:helpdesk@localhost:5432   # sem o nome do banco
bin/rails db:prepare db:seed
bin/rails server
```

## Verificar

```bash
bundle exec rspec
bundle exec rubocop
bundle exec brakeman -q --no-pager
```

O esquema do banco fica em `db/structure.sql`, não em `schema.rb`, porque guarda triggers e FKs compostas (invariante 8). O `db:migrate` precisa do `pg_dump` no PATH.
