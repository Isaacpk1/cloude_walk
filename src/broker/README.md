# broker — webhook da plataforma → Kafka

Reproduz o broker do desenho atual da CloudWalk ([ADR-007](../../docs/08-decisoes-de-arquitetura.md#adr-007--broker-de-webhooks-como-serviço-separado)). Recebe o webhook assinado da plataforma, confere a assinatura e o contrato e publica em `helpdesk.agent.inbound.v1`, com a chave `conversation_id` ([07, seções 3.1, 5.2 e 6](../../docs/07-arquitetura.md#52-webhook-plataforma--broker-e-evento-em-agentinbound)). Não tem banco.

| Resposta | Quando | O que acontece no Kafka |
| --- | --- | --- |
| `200 published` | Assinatura e contrato válidos, Kafka confirmou (`acks=all`) | Uma mensagem em `helpdesk.agent.inbound.v1`, com o corpo igual ao recebido e os cabeçalhos `event_id`, `traceparent` e `schema` |
| `200 duplicate` | O mesmo `event_id` já foi publicado por esta réplica | Nada novo. Devolve partição e offset da primeira publicação |
| `401 unauthorized` | Assinatura ausente, malformada, de outro segredo, corpo alterado ou fora de ±5 min (RNF-23) | Nada, nem na DLQ |
| `422 invalid` | Assinado, mas fora do contrato `agent_inbound`, `X-Helpdesk-Event-Id` diferente do corpo ou sem `traceparent` válido (RNF-28, RF-56) | O corpo vai para `helpdesk.agent.dlq.v1` com `dlq_reason`, `dlq_source` e `dlq_violations`. Sem retentativa (RN-44) |
| `503 unavailable` | Kafka não confirmou a escrita (nem na DLQ) | Nada confirmado. A plataforma tenta de novo pelo outbox, com o mesmo `event_id` |
| `503 in_flight` | Outra entrega do mesmo `event_id` está publicando agora | A plataforma tenta de novo e recebe `duplicate` |

A deduplicação por `event_id` fica em memória, por réplica: o broker não tem banco. O efeito único é garantido pelos consumidores (`processed_events`, invariante 3). Os logs saem em JSON com `trace_id`, sem o corpo do evento (RN-51).

| Variável | Padrão | Para quê |
| --- | --- | --- |
| `BROKER_WEBHOOK_SECRET` | `dev-secret-broker` fora de produção | Segredo do HMAC. Precisa ser o mesmo na plataforma (`worker`) |
| `KAFKA_BROKERS` | `localhost:9092` | Kafka (no Compose, `kafka:9092`) |
| `KAFKA_MESSAGE_TIMEOUT_MS` | `5000` | Quanto o broker espera a confirmação antes de responder `503` |
| `PORT` | `4100` | Porta HTTP |

```bash
bundle exec puma      # http://localhost:4100 (POST /webhooks, GET /up)
bundle exec rspec     # sem Kafka: o WaterDrop grava em memória (cliente Buffered)
bundle exec rubocop
```
