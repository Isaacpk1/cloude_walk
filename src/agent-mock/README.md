# agent-mock — agente de IA simulado

Faz o papel do agente de IA da CloudWalk ([ADR-008](../../docs/08-decisoes-de-arquitetura.md#adr-008--agente-de-ia-mock-determinístico)). Consome `helpdesk.agent.inbound.v1`, decide por regras determinísticas e publica a ação em `helpdesk.agent.outbound.v1` ([07, seções 3.1, 5.2 e 5.3](../../docs/07-arquitetura.md#53-ação-do-agente-em-agentoutbound)). Não tem banco e nunca lê o Postgres da plataforma (invariante 12).

| Evento recebido | O que o agente faz |
| --- | --- |
| Fora do contrato `agent_inbound` (ou JSON malformado) | Publica o corpo original em `helpdesk.agent.dlq.v1` com `dlq_reason`, `dlq_source=agent-mock`, `dlq_violations`, `event_id` e `traceparent`. Sem retentativa (invariante 10) |
| `deadline_at` já chegou no relógio do agente (no limite exato inclusive) | Descarta e loga `agent.expired` (07, seção 6, "Agente lento ou fora do ar") |
| Perfil mudo (do ambiente ou escolhido pelo simulador) | Consome e não responde (`agent.muted`) |
| Falha sorteada (`AGENT_FAILURE_RATE`) | A ação não sai (`agent.failed`). Não levanta erro: com a mesma semente o evento falharia de novo para sempre |
| `ticket.ai_turns >= 10` | `escalate` com `limite_de_trocas` (RN-33) |
| Caso normal | Primeira regra de `config/scenarios.yml` que casar no texto de **todas** as `pending_messages`; sem regra, `reply` padrão |

Regras padrão: pedido de humano → `escalate` (RN-34); estorno, troca de conta ou limite → `escalate` (RN-35); "resolvido", "resolveu", "deu certo" → `resolve` só quando afirmativos (RN-36): negação até 3 palavras antes ("ainda não está resolvido", "nada foi resolvido") ou pergunta ("resolveu?") não confirmam, e a IA segue com `reply` (recursos genéricos de regra `negations` + `negation_window` e `ignore_questions`, validados na subida); repasse, transação ou taxa → consulta sintética + `reply`. Cliente com `customer.verified: false` não tem consulta de dados de conta: o agente pede identificação (RN-05). A taxa não é dado de conta e segue liberada.

As consultas (`get_settlement_status`, `get_transaction_status`, `get_fee`) são locais e sintéticas: o resultado sai de um hash da semente e dos argumentos. Cada uma vira um item de `tool_calls` com `tool`, `args`, `result` e `duration_ms` (sintético). Nenhuma movimenta dinheiro ou altera cadastro (RN-35).

Toda ação é validada contra `agent_outbound` antes de sair. Se não passar, é defeito do agente: vai para a DLQ com `dlq_reason=acao_invalida` e nada sai em outbound. A ação publicada leva:

- chave `conversation_id`; cabeçalhos `event_id` (da ação), `traceparent` (o mesmo recebido, RF-56) e `schema`;
- `in_reply_to`, `conversation_id`, `brand`, `turn`, `context_until_seq` e `assignment_version` iguais aos do evento;
- `agent`: `model: mock-deterministico`, `version` (`lib/agent_mock/version.rb`) e `config_hash` (`sha256:` do JSON canônico da configuração efetiva **do perfil daquele evento**, RN-37);
- `timing`: `received_at`, `responded_at` e `agent_ms` = `responded_at - received_at`, a execução simulada inteira: latência sorteada mais a soma dos `duration_ms` das consultas, que também ocupam a thread (RNF-03). Determinístico para a mesma entrada e semente.

A publicação é síncrona (`produce_sync`, `acks=all`, idempotência). Se o Kafka não confirmar, o erro sobe, o Karafka não confirma o offset daquele evento e ele volta (07, seção 6). O offset é marcado evento a evento.

**Idempotência.** O agente não guarda estado: o mesmo evento entregue de novo gera outra ação, igual no conteúdo, com outro `event_id`. Quem garante o efeito único é a plataforma (`processed_events` e uma ação final por turno; RN-47, RN-56). É o caso mais difícil para a plataforma, e é o que um agente real com LLM faria.

## Perfil em tempo de execução (bloco 08)

O simulador (`channels-mock`) troca o perfil sem reiniciar o agente (RF-38). Ele grava o nome do perfil num Redis de controle e o agente lê a cada evento, com um `MGET` (`lib/agent_mock/profile_source.rb`):

| Chave | Vale para |
| --- | --- |
| `helpdesk:agent-mock:profile:brand:<marca>` | Eventos daquela marca (`brand` do evento: `infinitepay`, `jim`) |
| `helpdesk:agent-mock:profile:global` | Todas as marcas sem perfil próprio |

Ordem: marca → global → `AGENT_PROFILE`. O valor é só o nome do perfil (`rapido`, `lento`, `mudo`). O escopo mais fino é a marca: o evento traz o `cus_<id>` da plataforma, não o `account_id` nem o `customer_ref` do simulador, e o agente não consulta o Postgres para traduzir (invariante 12).

| Perfil | Latência | O que demonstra na plataforma |
| --- | --- | --- |
| `rapido` | 50–150 ms | Caminho feliz: resposta antes de qualquer aviso |
| `lento` | 16–18 s (sorteada com a semente e o `event_id`) | O turno abre ~1,5 s depois da primeira mensagem (RN-55). A resposta chega a ~17,5–19,5 s do ciclo: depois do aviso de progresso dos 15 s (RN-57) e antes do prazo de 20 s do turno (RN-46) |
| `mudo` | não responde | Timeout do turno aos 20 s e handoff para a fila humana (RN-46, RN-33) |

Todos os perfis são montados na subida (perfil inválido no YAML derruba a subida). As sobreposições `AGENT_*` do ambiente valem em qualquer perfil escolhido: com `AGENT_LATENCY_MS=200`, o `lento` do simulador também responde em 200 ms. O `config_hash` da ação é o do perfil efetivo, igual ao que o mesmo perfil teria pelo `AGENT_PROFILE`.

**Falhas da fonte.** Redis fora do ar, lento (timeout de 200 ms, sem reconexão) ou com um perfil desconhecido gravado: o agente usa o `AGENT_PROFILE`, loga `agent.profile_source_failed` ou `agent.profile_unknown` (warn, com `trace_id` e `fallback`) e segue consumindo. Sem `AGENT_CONTROL_REDIS_URL`, não há fonte e vale só o `AGENT_PROFILE`, como antes. Os logs `agent.published`, `agent.muted` e `agent.failed` trazem `profile` e `profile_source` (`brand`, `global` ou `env`).

## Configuração

`config/scenarios.yml` tem a semente, os perfis, as tools, as regras e os textos. As variáveis `AGENT_*` do perfil (semente, latência, falha, mudo) sobrepõem o perfil e entram no `config_hash`; as de Kafka e `AGENT_CONCURRENCY` não.

| Variável | Padrão | Para quê |
| --- | --- | --- |
| `KAFKA_BROKERS` | `localhost:9092` | Kafka (no Compose, `kafka:29092`) |
| `KAFKA_MESSAGE_TIMEOUT_MS` | `5000` | Quanto o produtor espera a confirmação antes de falhar |
| `AGENT_CONSUMER_GROUP` | `agent-mock` | Grupo do consumidor, separado do `consumer` da plataforma |
| `AGENT_PROFILE` | `rapido` | Perfil padrão: `rapido` (50–150 ms), `lento` (16–18 s) ou `mudo` (não responde) |
| `AGENT_CONTROL_REDIS_URL` | vazio | Redis de controle onde o simulador grava o perfil (no Compose, `redis://redis:6379/1`, banco separado do Sidekiq). Vazio: só o `AGENT_PROFILE`. Não entra no `config_hash`; o perfil escolhido entra |
| `AGENT_SEED` | `42` | Semente da latência, da falha e das consultas (RNF-30) |
| `AGENT_LATENCY_MS` | do perfil | Fixa (`2000`) ou faixa (`1000-3000`) |
| `AGENT_FAILURE_RATE` | do perfil | De `0` a `1`: fração de eventos sem resposta |
| `AGENT_MUTE` | do perfil | `true` ou `false` |
| `AGENT_CONCURRENCY` | `48` | Threads do Karafka (inteiro ≥ 1). A latência simulada ocupa a thread: vazão ≈ concorrência ÷ latência, ~24 turnos/s com 48 e o agente a 2 s (07, seção 7). Não entra no `config_hash`: muda a vazão, não a decisão |

Mesma entrada + mesma configuração + mesma semente = mesma ação, exceto `event_id` e `timing`. A latência e a falha são sorteadas por `event_id`, então não dependem da ordem de chegada nem da partição. Configuração inválida (perfil desconhecido, taxa fora de 0..1, tool fora do catálogo, regra mal formada, `AGENT_CONCURRENCY` < 1) derruba a subida.

Os logs saem em JSON no stdout, com `trace_id`, `event_id`, `conversation_id`, decisão, regra e duração. O texto do cliente e o `display_name` nunca vão para o log (RN-51).

## Como rodar

```bash
bundle exec karafka server                    # consome helpdesk.agent.inbound.v1
AGENT_PROFILE=mudo bundle exec karafka server # E2: agente fora do ar
bundle exec rspec                             # sem Kafka: karafka-testing e WaterDrop em memória
bundle exec rubocop
```

## Motor com LLM (Gemini; ADR-030)

`AGENT_ENGINE=gemini` e `GEMINI_API_KEY` no `.env` (e `docker compose up -d agent-mock`). A política continua por regra; o Gemini só redige a resposta das consultas e do caso padrão. Falha ou teto de chamadas voltam à resposta das regras (`agent.llm_fallback` no log). Use só dados sintéticos. Variáveis: `GEMINI_MODEL`, `GEMINI_TEMPERATURE`, `GEMINI_TIMEOUT_S`, `GEMINI_MAX_CONCURRENCY`, `GEMINI_MAX_CALLS` (`.env.example`). `agent.model` e `config_hash` da ação refletem o modelo e o prompt.
