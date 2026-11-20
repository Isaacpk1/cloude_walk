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

```bash
bundle exec rackup -p 4000   # http://localhost:4000
bundle exec rspec
bundle exec rubocop
```
