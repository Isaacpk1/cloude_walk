# channels-mock — provedores simulados e simulador do cliente

Faz o papel dos provedores de canal (RF-04, [ADR-012](../../docs/08-decisoes-de-arquitetura.md#adr-012--canais-simulados-como-provedores-externos), [ADR-018](../../docs/08-decisoes-de-arquitetura.md#adr-018--canais-simulados-no-formato-dos-provedores-reais)). A plataforma nunca fala direto com o cliente, só com o provedor.

**Bloco 02:** só o chat do app, na entrada. O simulador monta o webhook no formato do app (`message_id`, `account_id`, `customer_ref`, `text`, `sent_at`), valida contra o contrato `chat_webhook` e envia para `POST {PLATFORM_URL}/webhooks/chat/<conta>` com `traceparent`. WhatsApp, e-mail e o recebimento das respostas entram nos blocos 05 e 15.

O histórico de envios fica só em memória (docs/10, seção 3.4). O botão **Reenviar o mesmo ID** reentrega o mesmo corpo, como um provedor faria, para conferir a deduplicação (RNF-15).

| Variável | Padrão | Para quê |
| --- | --- | --- |
| `PLATFORM_URL` | `http://localhost:3000` | Para onde o webhook vai (no Compose, `http://web:3000`) |
| `PLATFORM_PUBLIC_URL` | `http://localhost:3000` | Links para a conversa, abertos no navegador |

```bash
bundle exec rackup -p 4000   # http://localhost:4000
bundle exec rspec
bundle exec rubocop
```
