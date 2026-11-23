# channels-mock — provedores simulados e simulador do cliente

Faz o papel dos provedores de canal (RF-04, [ADR-012](../../docs/08-decisoes-de-arquitetura.md#adr-012--canais-simulados-como-provedores-externos), [ADR-018](../../docs/08-decisoes-de-arquitetura.md#adr-018--canais-simulados-no-formato-dos-provedores-reais)). A plataforma nunca fala direto com o cliente, só com o provedor.

**Bloco 02:** só o chat do app, na entrada. O simulador monta o webhook no formato do app (`message_id`, `account_id`, `customer_ref`, `text`, `sent_at`), valida contra o contrato `chat_webhook` e envia para `POST {PLATFORM_URL}/webhooks/chat/<conta>` com `traceparent`. **Bloco 05:** o lado do provedor do chat recebe as respostas da plataforma (seção abaixo). WhatsApp e e-mail entram no bloco 15.

O histórico de envios fica só em memória (docs/10, seção 3.4). O botão **Reenviar o mesmo ID** reentrega o mesmo corpo, como um provedor faria, para conferir a deduplicação (RNF-15).

| Variável | Padrão | Para quê |
| --- | --- | --- |
| `PLATFORM_URL` | `http://localhost:3000` | Para onde o webhook vai (no Compose, `http://web:3000`) |
| `PLATFORM_PUBLIC_URL` | `http://localhost:3000` | Links para a conversa e a linha do tempo, abertos no navegador |
| `PROVIDER_SECRET_<CONTA>` | `dev-secret-<conta>` | Segredo da conta (ex.: `PROVIDER_SECRET_INFINITEPAY_CHAT_MOCK`), igual ao da plataforma |
| `CHAT_PROVIDER_FAULT` | `none` | Falha inicial do provedor do chat: `none`, `lose_ack`, `unavailable` ou `reject` |
| `CHAT_PROVIDER_FAULT_TIMES` | `1` | Quantas entregas a falha inicial afeta |
| `CHAT_STATUS_MAX_ATTEMPTS` | `5` | Tentativas do callback de status antes de desistir |
| `AGENT_CONTROL_REDIS_URL` | vazio | Redis de controle do perfil do agente mock (no Compose, `redis://redis:6379/1`, o mesmo do agent-mock). Vazio desliga o seletor |

## Provedor do chat: envio das respostas (bloco 05)

A plataforma entrega a resposta ao cliente chamando a API do app ([07, seção 5.0](../../docs/07-arquitetura.md#50-webhooks-dos-canais-entrada-e-saída)):

```
POST /provider/chat/<conta>/messages
Content-Type: application/json
Idempotency-Key: <delivery_id>          obrigatório, estável nas retentativas
X-Conversation-Id: tkt_<ticket_id>      obrigatório
X-Conversation-Seq: <seq>               obrigatório, inteiro positivo
X-Helpdesk-Signature: t=<unix>,v1=<hex> HMAC do corpo com o segredo da conta (ADR-019)
traceparent: 00-<trace_id>-<span>-01

{ "customer_ref": "cus_ref_000021", "text": "...", "reply_to": "<message_id do cliente>" }
```

| Resposta | Quando |
| --- | --- |
| `200 { "message_id": "chatmsg_<hex>", "status": "accepted" }` | Aceita. Efeito e confirmação gravados juntos |
| `200` igual + `Idempotent-Replayed: true` | Mesma `Idempotency-Key`: a mesma resposta gravada, sem novo efeito (RNF-15) |
| `400 { "error": "idempotency_key_ausente" \| "conversa_ausente" \| "seq_invalida" }` | Cabeçalho obrigatório ausente ou inválido |
| `401 { "error": "assinatura_invalida", "reason": ... }` | Assinatura ausente, fora da janela de 5 min ou com outro segredo |
| `404 { "error": "conta_desconhecida" }` | Conta fora da lista |
| `409 { "error": "seq_anterior", "last_seq": n }` | Chave nova com `seq` menor que a última aceita na conversa ([07, seção 3.2](../../docs/07-arquitetura.md#32-escalação-e-handoff)) |
| `409 { "error": "seq_repetida", "last_seq": n }` | Chave nova com a mesma `seq` já aceita (seriam duas mensagens na mesma posição) |
| `422 { "error": "contrato_invalido" \| "idempotency_key_reutilizada" \| "recusada_pelo_provedor" }` | Fora do contrato `chat_send`; a mesma chave com outro corpo; recusa simulada |
| `503 { "error": "provedor_indisponivel" }` | Falha simulada, transitória, sem efeito |
| `504 { "error": "confirmacao_perdida" }` | Falha simulada: a mensagem **foi gravada**, só a confirmação se perdeu. Repetir com a mesma chave devolve a confirmação gravada |

Ordem das verificações: conta → falha `unavailable` → assinatura → cabeçalhos → contrato → idempotência e `seq` (sob um único lock, com o efeito).

**Falhas simuladas.** Escolha na tela ("Provedor do chat: falhas simuladas"), pelo ambiente (`CHAT_PROVIDER_FAULT`) ou pelo endpoint de controle. Cada falha vale para as próximas `times` entregas novas e depois volta a `none`:

```bash
curl -X POST localhost:4000/provider/chat/faults -H 'Content-Type: application/json' -d '{"fault":"lose_ack","times":1}'
```

**Callback de status.** Depois de aceitar uma mensagem, o provedor envia `delivered` para `POST {PLATFORM_URL}/webhooks/chat/<conta>/status`, assinado como o webhook de entrada, no contrato `chat_status` (`message_id`, `status`, `timestamp`). Vai por uma fila em memória com uma thread, fora do caminho da resposta. Conexão recusada ou `5xx` são repetidos (até `CHAT_STATUS_MAX_ATTEMPTS`, espera de 0,5 s dobrando); `4xx` é definitivo. Uma repetição da mesma chave não gera outro `delivered`. Na tela, cada resposta tem **Marcar como lida** (`read`) e **Simular falha de entrega** (`failed`).

**Na tela.** Cada envio do cliente mostra as respostas recebidas pelo provedor, ligadas pelo `reply_to` (= `message_id` do webhook do cliente), com `message_id`, `Idempotency-Key`, `seq`, repetições, `trace_id`, último status e o **tempo total**: chegada da resposta ao provedor − `sent_at` do envio (RNF-05, latência percebida). O `trace_id` do envio e o link para a linha do tempo levam até a mensagem original no painel. `/?atualizar=3` recarrega a página a cada 3 s.

O armazenamento é só em memória: reiniciar o mock apaga as mensagens aceitas e a última `seq` de cada conversa. Por isso uma retentativa depois de reiniciar é aceita como nova.

## Cenários de rajada (bloco 06)

Mandam várias mensagens do mesmo cliente em horários planejados, para ver o agrupamento em turnos e a corrida da resposta superada ([06, RN-55 e RN-56](../../docs/06-regras-de-negocio.md); [07, seção 3.4](../../docs/07-arquitetura.md)). Cada passo sai pelo mesmo caminho do formulário: webhook do chat no contrato `chat_webhook`, assinado com o segredo da conta, com a mesma conta do provedor, o mesmo `account_id` e o mesmo `customer_ref`, e um `message_id` novo. As mensagens aparecem na **Conversa** como as do formulário, com o tempo total das respostas.

| Cenário | Passos (s desde a largada) | O que demonstra |
| --- | --- | --- |
| `corrida-3s` — Corrida dos 3 s (RN-56) | "meu repasse não caiu" em 0; "é o de ontem, R$ 1.200" em 3 | O turno 1 sai aos 1,5 s com a mensagem 1. O desfecho depende da latência do agente. **Agente lento** (`AGENT_PROFILE=lento` ou `AGENT_LATENCY_MS` ≥ 2000): a mensagem 2 é gravada aos 3 s, antes da resposta do turno 1, que é rejeitada com `turno_superado`; o turno 2 sai aos 4 s (teto desde a primeira pendente) com as mensagens 1 e 2. **Agente rápido** (`AGENT_PROFILE=rapido`, padrão do Compose): o turno 1 é respondido e entregue antes dos 3 s, e a mensagem dos 3 s abre um ciclo novo. Para ver a rejeição, escolha o perfil Lento na seção "Perfil do agente mock" (ou suba com `AGENT_PROFILE=lento`). Vai servir ao eval do bloco 07 |
| `rajada-curta` — Rajada curta (RN-55) | 0; 0,5; 1,0 | Pausas menores que a janela de 1,5 s: as três entram num turno só, que sai ~1,5 s depois da última |
| `rajada-longa` — Rajada longa (RN-55, teto) | 0; 0,9; 1,8; 2,7; 3,6; 4,5 (sem empate com o teto) | A janela nunca fecha; o turno 1 sai no teto de 4 s desde a primeira, com as mensagens até 3,6 s. A de 4,5 s é gravada depois do teto e supera o turno 1 (RN-56); o turno 2 sai na volta seguinte do scheduler com todas as pendentes. Com o agente rápido, a resposta do turno 1 pode ser aplicada antes dos 4,5 s, e a última mensagem abre um ciclo novo |

Os passos ficam em `ChannelsMock::Scenarios::CATALOG` (`lib/channels_mock/scenarios.rb`). Cada execução roda numa thread própria e espera até o horário planejado (`largada + at`); os passos de uma execução saem em ordem, um depois do outro. A tela mostra, por passo, o horário planejado, o real (com o atraso em ms), o HTTP e o resultado da plataforma. Uma falha da plataforma num passo fica registrada e os passos seguintes continuam. Se a plataforma demorar a responder (até 5 s de timeout), o passo seguinte sai atrasado; o atraso aparece na coluna **Real**.

**Na tela:** seção "Cenários de rajada", escolha a conta e o cliente e clique no cenário. A página passa a se atualizar a cada 1 s (`/?atualizar=1`; "Parar" no cartão da conversa).

**Por script** (testes de ponta a ponta, eval do bloco 07):

```bash
curl -X POST localhost:4000/simulador/cenarios/corrida-3s -H 'Content-Type: application/json' \
  -d '{"account":"infinitepay-chat-mock","account_id":"acc_infinitepay_000021","customer_ref":"cus_ref_000021"}'
# 202 {"run_id":1,"scenario":"corrida-3s","status":"queued","status_url":"/simulador/cenarios/1"}

curl localhost:4000/simulador/cenarios/1
# 200 {"status":"finished","current_step":2,"total_steps":2,"steps":[{"step":1,"at":0.0,"planned_at":...,
#      "sent_at":...,"http_status":202,"outcome":"Confirmada","message_id":...,"trace_id":...}, ...]}
```

| Resposta | Quando |
| --- | --- |
| `202` | Execução criada; os passos saem em segundo plano |
| `404 { "error": "cenario_desconhecido" }` | Nome fora do catálogo |
| `422 { "error": "contrato_invalido" \| "pedido_invalido" }` | Cliente fora do contrato `chat_webhook` ou conta do provedor fora da lista. Nenhum passo é enviado |

O `message_id` e o `trace_id` de cada passo levam à mensagem e ao turno no painel. Os logs (`scenario.started`, `scenario.step_sent`, `scenario.finished`) são JSON e não trazem o texto nem o `account_id` e o `customer_ref` (RN-51). O histórico guarda as 20 execuções mais recentes, só em memória.

## Perfil do agente mock (bloco 08)

Escolhe o perfil do agent-mock **sem reiniciar o agente** (RF-38), para demonstrar o aviso de progresso e o timeout do turno ([06, RN-46 e RN-57](../../docs/06-regras-de-negocio.md)). O simulador grava o nome do perfil no Redis de controle; o agent-mock lê a cada evento novo ([README do agent-mock](../agent-mock/README.md#perfil-em-tempo-de-execução-bloco-08)). Nada passa pelo caminho do evento: se o simulador cair, o agente segue com o último perfil gravado.

| Perfil | Latência | O que demonstra |
| --- | --- | --- |
| `rapido` — Rápido | 50–150 ms | Caminho feliz: a resposta chega antes de qualquer aviso |
| `lento` — Lento | 16–18 s | Aviso de progresso aos 15 s (RN-57) e resposta antes do prazo de 20 s do turno (RN-46) |
| `mudo` — Sem resposta | não responde | Aviso de progresso aos 15 s, timeout do turno aos 20 s e o caso na fila humana (RN-46, RN-33) |

| Escopo | Chave no Redis | Vale para |
| --- | --- | --- |
| `global` | `helpdesk:agent-mock:profile:global` | Todas as marcas sem perfil próprio |
| `infinitepay-chat-mock`, `jim-chat-mock` | `helpdesk:agent-mock:profile:brand:<marca>` | Os eventos da marca da conta (tem precedência sobre o global) |

O escopo mais fino é a conta do provedor, que define a marca. Por cliente (`account_id`/`customer_ref`) não dá: o evento que o agente recebe traz o `cus_<id>` da plataforma, e o agente não consulta o Postgres (invariante 12). O perfil `padrao` apaga a escolha do escopo e volta a valer o `AGENT_PROFILE` do agente. A troca vale para o próximo evento que o agente consumir; um evento que já está na latência do perfil anterior termina nele.

**Na tela:** seção "Perfil do agente mock", com o perfil ativo de cada escopo e a origem (marca, global ou `AGENT_PROFILE`). **Por script** (evals, testes de ponta a ponta):

```bash
curl -X POST localhost:4000/simulador/agente/perfil -H 'Content-Type: application/json' -d '{"scope":"global","profile":"mudo"}'
# 200 {"available":true,"profiles":[...],"scopes":[{"scope":"global","brand":null,"profile":"mudo","effective":"mudo","source":"global"}, ...]}
curl localhost:4000/simulador/agente/perfil   # estado atual
```

| Resposta | Quando |
| --- | --- |
| `200` | Gravado (repetir a mesma escolha é inofensivo); o corpo é o estado de todos os escopos |
| `422 { "error": "perfil_desconhecido" \| "escopo_desconhecido" \| "pedido_invalido" }` | Perfil fora de `rapido`, `lento`, `mudo`, `padrao`; escopo fora da lista; JSON malformado. Nada é gravado |
| `503 { "error": "controle_desligado" \| "controle_indisponivel" }` | Sem `AGENT_CONTROL_REDIS_URL`; Redis fora do ar (timeout de 200 ms). O resto do simulador segue funcionando |

Os logs (`agent_profile.set`, `agent_profile.unavailable`) são JSON e trazem só escopo, marca e perfil (RN-51).

```bash
bundle exec rackup -p 4000   # http://localhost:4000
bundle exec rspec
bundle exec rubocop
```
