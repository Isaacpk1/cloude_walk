# 10 — Organização do repositório

Este documento diz **onde fica cada coisa** no repositório e **para que serve cada pasta**. A decisão e os motivos estão no [ADR-017](08-decisoes-de-arquitetura.md#adr-017--monorepo-com-o-código-em-src).

Regra de bolso: se você não sabe onde colocar um arquivo, procure a pergunta na seção [4. Onde fica?](#4-onde-fica). Se ela não estiver lá, a resposta entra neste documento no mesmo pull request.

## 1. Visão geral

```text
cloude_walk/
├── docs/                       # SRS 01–10: a fonte da verdade
├── src/                        # todo o código que roda
│   ├── platform/               # Rails 8: web, worker, consumer e scheduler
│   ├── broker/                 # webhook → Kafka (ADR-007)
│   ├── agent-mock/             # agente de IA simulado (ADR-008)
│   ├── channels-mock/          # provedores + simulador do cliente (ADR-012)
│   └── contracts/              # JSON Schemas versionados, usados por todos
├── tests/
│   └── e2e/                    # fluxos entre serviços (a partir do bloco 05)
├── infra/                      # a partir do bloco 03
│   ├── postgres/               # papéis e permissões do banco
│   ├── kafka/                  # tópicos e partições
│   └── observability/          # Prometheus, Grafana e OpenTelemetry
├── bench/                      # experimentos E1–E6 (a partir do bloco 17)
├── scripts/                    # utilitários de shell (quando houver)
├── .github/workflows/          # CI (ver seção 3.9)
├── docker-compose.yml
├── Makefile
├── .env.example
└── README.md · ROADMAP.md · AGENTS.md · CONTRIBUTING.md
```

## 2. Princípios

| # | Princípio | Por quê |
| --- | --- | --- |
| O1 | **Uma pasta por fronteira de rede.** Cada serviço em `src/` é uma aplicação com o próprio `Gemfile` e o próprio `Dockerfile` | O broker, o agente e os canais conversam com a plataforma só por HTTP ou Kafka (ADR-007, ADR-008, ADR-012). Em pastas separadas, um serviço não consegue importar os models de outro. Isso garante na estrutura que o agente nunca lê o Postgres (invariante 12) |
| O2 | **Os quatro processos da plataforma compartilham o código.** `web`, `worker`, `consumer` e `scheduler` saem de `src/platform/` | Os quatro gravam na mesma transação que o outbox e a auditoria (invariantes 1 e 2). Separá-los duplicaria models e regras |
| O3 | **Contratos num lugar neutro.** `src/contracts/` não pertence a nenhum serviço | Quatro serviços validam os mesmos esquemas (invariante 10). Se o esquema morasse num serviço, os outros copiariam e divergiriam |
| O4 | **Código por contexto de domínio, não por camada técnica.** `services/turns/`, não `services/validators/` | A regra fica perto de quem a usa. Quem procura "turnos" acha tudo num lugar |
| O5 | **Cada teste mora com o que testa.** Os testes de um serviço ficam no `spec/` dele. Só o que atravessa serviços vai para `tests/e2e/` | O `rspec` de cada serviço roda sem subir os outros. O e2e é caro e fica separado |
| O6 | **Só o Postgres tem migrations.** Redis e Kafka têm configuração, não esquema | O Postgres é a fonte da verdade (P2). Ver a [seção 5](#5-por-que-o-redis-não-tem-migration) |

## 3. Pasta por pasta

### 3.1 `src/platform/` — a plataforma (Rails 8)

É um app Rails padrão. Os quatro contêineres usam a mesma imagem e mudam só o comando de entrada.

```text
src/platform/
├── app/
│   ├── models/                 # tabelas do 07, seção 4
│   ├── services/               # regras de negócio, por contexto
│   │   ├── channel_adapters/   # webhook do provedor → mensagem normalizada (07, seção 5.0)
│   │   ├── ingestion/          # entrada da mensagem (invariante 1)
│   │   ├── turns/              # janela, abertura e validade do turno (RN-55 a RN-57)
│   │   ├── agent_actions/      # aplicar ou rejeitar a ação do agente
│   │   ├── triage/             # categoria e prioridade
│   │   ├── routing/            # avaliador de regras (ADR-003, ADR-013)
│   │   ├── assignment/         # atribuição e capacidade (RN-30, RN-31)
│   │   ├── handoff/            # escalação e resumo (RN-33, RN-39)
│   │   ├── delivery/           # entrega ao canal com delivery_id estável
│   │   ├── outbox/             # publicação e recuperação do outbox
│   │   ├── deadlines/          # consulta de prazos usada pelo scheduler (ADR-016)
│   │   └── rate_limit/         # limite por marca e canal (RNF-33)
│   ├── jobs/                   # Sidekiq: recebem só o ID e chamam um service
│   ├── consumers/              # Karafka: helpdesk.agent.outbound.v1
│   ├── controllers/            # ingestão dos canais, painel, configuração
│   │   └── webhooks/           # entrada dos provedores
│   ├── read_models/            # formato de leitura das telas (ConversationView, TimelineView) e suas fontes
│   ├── views/                  # Hotwire (Turbo + Stimulus)
│   ├── channels/               # ActionCable, sempre filtrado por marca
│   ├── policies/               # autorização por marca, equipe e perfil (RN-52)
│   └── javascript/controllers/ # Stimulus (importmap, sem build)
├── bin/
│   └── scheduler               # laço de 250 ms (ADR-016)
├── config/
│   ├── database.yml            # Postgres
│   ├── sidekiq.yml             # filas e pesos (07, seção 2)
│   ├── cable.yml               # ActionCable no Redis
│   ├── initializers/
│   │   ├── redis.rb            # conexão única do Redis
│   │   ├── sidekiq.rb
│   │   ├── opentelemetry.rb
│   │   └── logging.rb          # JSON, trace_id, PII mascarada (RN-51)
│   └── routes.rb
├── karafka.rb                  # consumers e roteamento dos tópicos
├── db/
│   ├── migrate/                # as migrations
│   ├── structure.sql           # gerado pelo db:migrate; nunca editar à mão
│   ├── seeds.rb                # ponto de entrada do `make seed`
│   └── seeds/synthetic.rb      # gerador sintético por semente (RF-61)
├── spec/                       # espelha app/
│   ├── models/ services/ jobs/ consumers/ requests/ system/
│   ├── concurrency/            # testes fora da transação de teste
│   ├── factories/
│   └── support/
├── Gemfile
└── Dockerfile
```

**O que não entra aqui:** código do broker, do agente ou dos canais; schemas JSON (vão para `src/contracts/`); scripts de carga (vão para `bench/`).

**Regras de cada subpasta:**

- **`services/`**: um objeto por operação (`Ingestion::Receive`, `Turns::Open`), com o método `.call`. É aqui que mora a regra. Controllers, jobs e consumers só traduzem a entrada e chamam um service.
- **`jobs/`**: o job recebe só o ID do item do outbox ou da entidade, nunca o payload (ADR-016). Não decide nada sozinho.
- **`consumers/`**: valida o contrato, grava `processed_events` na mesma transação do efeito (invariante 3) e delega a um service.
- **`channels/`**: toda inscrição confere a marca do usuário (invariante 6).

### 3.2 `src/broker/` — webhook → Kafka

App Rack/Roda pequeno, com WaterDrop (ADR-007).

```text
src/broker/
├── app.rb                      # rotas
├── lib/broker/
│   ├── signature.rb            # usa HelpdeskContracts::Signature (RNF-23, ADR-019): só lê o segredo e responde 401
│   ├── publisher.rb            # publica em helpdesk.agent.inbound.v1 e, se fora do contrato, em helpdesk.agent.dlq.v1
│   ├── dedup.rb                # event_id já publicado, em memória e por réplica
│   └── log.rb                  # logs em JSON com trace_id
├── config/waterdrop.rb         # produtor Kafka (acks=all, idempotente)
├── config/puma.rb              # porta 4100
├── spec/
├── config.ru · Gemfile · Dockerfile
```

Não tem banco. Se o Kafka cair, responde erro e a plataforma retenta pelo outbox. As respostas estão no [07, seção 5.2](07-arquitetura.md#52-webhook-plataforma--broker-e-evento-em-agentinbound) e no `README.md` do serviço.

### 3.3 `src/agent-mock/` — agente simulado

Consome `helpdesk.agent.inbound.v1` e publica em `helpdesk.agent.outbound.v1` (ADR-008).

```text
src/agent-mock/
├── karafka.rb
├── app/consumers/
├── lib/agent_mock/
│   ├── scenarios/              # respostas determinísticas por intenção
│   ├── tools/                  # consultas sintéticas (repasse, conta)
│   └── failure_modes.rb        # latência, taxa de falha, modo mudo
├── config/scenarios.yml        # perfis rápido, lento e sem resposta
├── spec/
├── Gemfile · Dockerfile
```

Não tem banco e nunca lê o Postgres da plataforma (invariante 12).

### 3.4 `src/channels-mock/` — provedores e simulador

Faz o papel do app, do WhatsApp e do e-mail, e hospeda o simulador do cliente (RF-04, ADR-012).

```text
src/channels-mock/
├── app.rb
├── lib/channels_mock/
│   ├── providers/              # chat/ whatsapp/ email/: formato de cada canal
│   └── delivery_api.rb         # recebe as respostas da plataforma
├── views/                      # tela do simulador
├── spec/
├── config.ru · Gemfile · Dockerfile
```

Guarda o que recebeu só em memória, para a tela do simulador. Não é fonte da verdade.

### 3.5 `src/contracts/` — contratos

É uma gem local (`helpdesk_contracts`), carregada pelos quatro serviços com `gem "helpdesk_contracts", path: "../contracts"`.

```text
src/contracts/
├── v1/
│   ├── schemas/
│   │   ├── normalized_message.json       # 07, seção 5.1
│   │   ├── agent_inbound.json            # 07, seção 5.2
│   │   ├── agent_outbound.json           # 07, seção 5.3
│   │   └── channels/                     # formato real de cada provedor (07, seção 5.0; ADR-018)
│   │       ├── whatsapp.json             # webhook da Cloud API (mensagens e status)
│   │       ├── email_push.json           # notificação push do Gmail
│   │       ├── email_message.json        # recurso users.messages.get
│   │       ├── chat.json · chat_status.json   # chat do app (formato próprio)
│   │       ├── whatsapp_send_response.json · email_history.json
│   │       └── outbound/                 # chamadas de envio: whatsapp, email, chat
│   └── fixtures/
│       ├── valid/<contrato>/             # exemplos que devem passar
│       └── invalid/<contrato>/           # exemplos que devem ir para a DLQ
│           └── expected.yml              # motivo esperado (pointer e type) de cada arquivo
├── lib/helpdesk_contracts.rb             # validador único (json_schemer)
├── lib/helpdesk_contracts/signature.rb   # HMAC dos webhooks com janela anti-replay (RNF-23, ADR-019)
├── spec/
└── helpdesk_contracts.gemspec
```

Uma mudança incompatível cria `v2/` ao lado de `v1/`, nunca edita `v1/` (07, seção 5.4).

### 3.6 `tests/e2e/` — ponta a ponta

Testes que só fazem sentido com o Compose de pé. Exemplo: o simulador envia "meu repasse não caiu" e a resposta volta pelo canal (critério do bloco 05). Cada arquivo corresponde a um roteiro de demonstração do [roadmap](../ROADMAP.md). Roda com `make e2e`, fora do `rspec` de cada serviço.

### 3.7 `infra/` — infraestrutura sem código de negócio

| Pasta | Conteúdo | Por quê |
| --- | --- | --- |
| `infra/postgres/` | `init.sql`: cria o papel da aplicação e o papel de migração | O `REVOKE UPDATE, DELETE ON audit_events` (RN-54) só funciona se a aplicação não for dona da tabela |
| `infra/kafka/` | `topics.yml` (nome, partições, retenção) e `create-topics.sh` | É o "esquema" do Kafka: os três tópicos do ADR-004, com 48 partições (07, seção 7). Roda num contêiner de uso único, `kafka-init` |
| `infra/observability/` | `prometheus.yml`, painéis do Grafana em JSON, configuração do OpenTelemetry | Os painéis versionados permitem repetir o experimento (RNF-22) |

### 3.8 `bench/` — experimentos

```text
bench/
├── k6/                         # um script por experimento (E1, E5)
├── analysis/                   # pandas + Plotly (ADR-010)
└── results/
    └── AAAA-MM-DD-e1-referencia/  # semente, configuração, taxas e saídas
```

Um resultado sem a semente e a configuração não conta como evidência (RNF-30).

### 3.9 Raiz

| Arquivo | Para |
| --- | --- |
| `docker-compose.yml` | Os contêineres do ADR-011 e o `kafka-init`. Fica na raiz para `make up` funcionar sem argumentos |
| `Makefile` | Os comandos do dia a dia: `up`, `down`, `logs`, `seed`, `reset`, `test`, `lint`, `security`, `check` e `help`. `e2e` entra no bloco 05 e `bench` no bloco 19 |
| `.env.example` | Todas as variáveis, com valores de desenvolvimento. O `.env` real não vai para o git |
| `scripts/` | Utilitários de shell que não pertencem a um serviço (ex.: conferir o ambiente). O seed fica no Rails, porque usa os models |
| `.github/workflows/ci.yml` | CI: um job por serviço (`platform`, `contracts`, `broker`, `channels-mock`), em paralelo. Cada serviço novo ganha o próprio job, e o `ruby/setup-ruby` lê a versão do `.ruby-version` do serviço (nunca fixa a versão no YAML) |

## 4. Onde fica?

| Pergunta | Resposta |
| --- | --- |
| Criar ou alterar uma tabela | `src/platform/db/migrate/`. Gere com `bin/rails g migration` e confira o `structure.sql` gerado |
| Trigger, FK composta ou outra regra que o Rails não representa | Na migration, com `execute` quando preciso. O formato `structure.sql` (em vez de `schema.rb`) existe para guardar essas regras (invariante 8) |
| Índice único que carrega regra de negócio | Na mesma migration da tabela. A lista de restrições obrigatórias está no 07, seção 4 |
| Permissões do banco (auditoria só de inserção) | `infra/postgres/init.sql` para os papéis e uma migration para o `REVOKE` |
| Dados iniciais (marca, fila, cliente, bot) | `src/platform/db/seeds/synthetic.rb`, chamado por `db/seeds.rb`. Rode com `make seed`; a semente vem de `SEED` no `.env` |
| Versão do Ruby | No `.ruby-version` de cada serviço em `src/` (hoje Ruby 4.0.10, ADR-001). O CI e o `Makefile` leem esse arquivo; o `ARG RUBY_VERSION` do `Dockerfile` e o `TargetRubyVersion` do `.rubocop.yml` dos serviços repetem o mesmo valor. Ao trocar de versão, mude todos juntos e confira se o `ruby/setup-ruby` já publica a versão para o `ubuntu-latest` |
| Conexão com o Redis | `src/platform/config/initializers/redis.rb`, com a URL em `REDIS_URL` |
| Filas e pesos do Sidekiq | `src/platform/config/sidekiq.yml` |
| ActionCable no Redis | `src/platform/config/cable.yml` |
| Rate limit por marca e canal | `src/platform/app/services/rate_limit/` |
| Criar um tópico Kafka ou mudar as partições | `infra/kafka/topics.yml` |
| Consumir um tópico na plataforma | `src/platform/karafka.rb` e `app/consumers/` |
| Publicar no Kafka | O broker (`src/broker/lib/broker/publisher.rb`) publica em `inbound` e o agente mock em `outbound`. A plataforma envia ao broker por webhook e só publica direto na DLQ, pelo próprio Karafka |
| Prazos (janela, aviso, timeout, SLA) | Colunas na migration de `tickets`; consulta em `app/services/deadlines/`; laço em `bin/scheduler` |
| Esquema de um evento | `src/contracts/v1/schemas/` |
| Exemplo de payload para teste | `src/contracts/v1/fixtures/` |
| Conta de um provedor (qual marca e canal recebem `/webhooks/:channel/:provider_account`) | Tabela `provider_accounts` (model `ProviderAccount`), criada pelo seed. A marca e a conta nunca vêm do corpo do webhook (07, seção 5.0; ADR-019) |
| Segredo do webhook plataforma → broker | `BROKER_WEBHOOK_SECRET` no `.env`, o mesmo no `worker` e no `broker`. Fora de produção, os dois usam `dev-secret-broker` |
| Publicação do outbox no broker (reserva, retentativas, descarte) | `src/platform/app/services/outbox/publish.rb` (`Outbox::Publish`), chamado pelo `OutboxJob`. A recuperação dos itens abertos fica em `outbox/recover.rb` e roda no `worker` até o `scheduler` do bloco 08 |
| Abertura do turno e envelope do evento ao agente | `src/platform/app/services/turns/open.rb` e `turns/envelope.rb` |
| Ver as mensagens de `helpdesk.agent.inbound.v1` | `make topics` (chave, cabeçalhos e corpo) |
| Por que um evento não foi publicado | Linha do tempo do atendimento: escolha o evento de falha para ver a origem. O histórico vem de `audit_events` (`agent_event.*`) |
| Assinatura de webhook (gerar e conferir) | `src/contracts/lib/helpdesk_contracts/signature.rb` (`HelpdeskContracts::Signature`). É usada pela plataforma, pelo `channels-mock` e pelo broker |
| Chaves do Active Record Encryption | `AR_ENCRYPTION_*` no ambiente, lidas em `src/platform/config/application.rb` |
| Adaptador de entrada de um canal (webhook → mensagem normalizada) | `src/platform/app/services/channel_adapters/<canal>.rb` (`ChannelAdapters::Chat`). O nome evita confusão com `app/channels/`, que é do ActionCable |
| Variável de ambiente nova | `.env.example`, com comentário, e no `environment` do serviço no Compose |
| O que a tela de conversa e a linha do tempo leem | `src/platform/app/read_models/`: `ConversationView` e `TimelineView`, lidos pelo `ConversationReader`. Hoje alimentados por `SyntheticConversations`; o adaptador dos registros reais entra na mesma pasta, com a mesma interface |
| Teste de regra (RN) | `src/platform/spec/services/<contexto>/`, com o ID no `describe` |
| Teste de concorrência | `src/platform/spec/concurrency/`, marcado com `:concurrency` |
| Teste que atravessa serviços | `tests/e2e/` |
| Painel do Grafana | `infra/observability/grafana/dashboards/` |
| Script de carga | `bench/k6/` |

## 5. Por que o Redis não tem migration

Migration existe para mudar o esquema de dados que precisam sobreviver. Só o Postgres guarda esse tipo de dado (P2, ADR-006).

| Componente | Guarda | Tem migration? | Onde fica a configuração |
| --- | --- | --- | --- |
| Postgres | Atendimentos, mensagens, configuração, outbox, auditoria | **Sim:** `src/platform/db/migrate/` | `config/database.yml`, `infra/postgres/init.sql` |
| Redis | Filas do Sidekiq, pub/sub do ActionCable, contadores do rate limit | **Não.** São estruturas criadas sob demanda e descartáveis. Se o Redis perder tudo, o outbox republica (ADR-005, ADR-016) | `config/initializers/redis.rb`, `config/sidekiq.yml`, `config/cable.yml` |
| Kafka | Eventos em trânsito entre plataforma, broker e agente | **Não como migration**, mas os tópicos são declarados em `infra/kafka/topics.yml` e criados pelo `kafka-init` | `infra/kafka/`, `karafka.rb` de cada serviço |

Consequência prática: nenhum dado que precise ser consultado depois pode existir só no Redis ou só no Kafka. Se precisar, ele ganha uma tabela e uma migration.

## 6. Do contêiner ao código

| Contêiner (Compose) | Código | Comando |
| --- | --- | --- |
| `web` | `src/platform` | `bin/rails server` |
| `worker` | `src/platform` | `bundle exec sidekiq -C config/sidekiq.yml` |
| `consumer` | `src/platform` | `bundle exec karafka server` |
| `scheduler` | `src/platform` | `bin/scheduler` |
| `broker` | `src/broker` | `bundle exec puma` |
| `agent-mock` | `src/agent-mock` | `bundle exec karafka server` |
| `channels-mock` | `src/channels-mock` | `bundle exec puma` |
| `kafka-init` | `infra/kafka` | `create-topics.sh` (roda e sai) |
| `postgres`, `redis`, `kafka`, `prometheus`, `grafana` | `infra/` | Imagens oficiais |

## 7. Convenções

- **Pastas** em `kebab-case` fora do Ruby (`agent-mock`, `channels-mock`). **Arquivos Ruby** em `snake_case`, como manda o Zeitwerk.
- **Namespaces** seguem a pasta: `app/services/turns/open.rb` define `Turns::Open`.
- **Um serviço novo** em `src/` exige ADR (O1). Uma pasta nova dentro de um serviço exige só uma linha neste documento.
- **Arquivos gerados** (`structure.sql`, `Gemfile.lock`) vão para o git, mas nunca são editados à mão.
- **Pastas marcadas "a partir do bloco NN"** ainda não existem. Elas são criadas no bloco indicado, no lugar descrito aqui.
