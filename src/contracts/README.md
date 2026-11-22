# helpdesk_contracts

Gem local com os contratos versionados do help desk (07, seção 5; RNF-28; invariante 10). Os quatro serviços a carregam com:

```ruby
gem "helpdesk_contracts", path: "../contracts"
```

## Uso

```ruby
HelpdeskContracts.validate!(:agent_outbound, payload)   # devolve o payload ou levanta InvalidPayload
HelpdeskContracts.valid?(:agent_inbound, payload)       # true ou false
HelpdeskContracts.errors(:normalized_message, payload)  # [Violation(pointer, type, message), ...]
HelpdeskContracts.contract_for(payload)                 # contrato pelo campo schema, ou nil
```

- `payload` pode ser um `Hash` (chaves String ou Symbol) ou o corpo bruto em JSON. O validador não muta o payload.
- `InvalidPayload#violations` traz a lista completa. Payload inválido é falha permanente: vai para a DLQ, sem retentativa (RN-44).
- Contrato desconhecido (`:refund`) levanta `ArgumentError`. É erro de programação, não de payload.

## Contratos

### Internos

| Contrato | Arquivo | Campo `schema` | Origem | Obrigatórios |
| --- | --- | --- | --- | --- |
| `:normalized_message` | `v1/schemas/normalized_message.json` | `helpdesk.normalized_message.v1` | 07, 5.1 | `schema`, `channel`, `brand`, `provider_account`, `external_id`, `sender.channel_identity`, `content.type`, `content.text`, `received_at`, `trace_id`. Opcionais no e-mail: `content.subject` e `content.attachments[]` (`filename`, `content_type`, `size_bytes`, só metadados) |
| `:agent_inbound` | `v1/schemas/agent_inbound.json` | `helpdesk.agent_event.v1` | 07, 5.2 | `schema`, `event_id`, `event_type`, `occurred_at`, `conversation_id`, `brand`, `locale`, `ticket`, `customer`, `context`, `turn`, `context_until_seq`, `assignment_version`, `deadline_at`; `message` quando `event_type=message.created` |
| `:agent_outbound` | `v1/schemas/agent_outbound.json` | `helpdesk.agent_action.v1` | 07, 5.3 | `schema`, `event_id`, `in_reply_to`, `conversation_id`, `brand`, `turn`, `context_until_seq`, `assignment_version`, `action`, `agent`. Mais o conteúdo da ação (tabela abaixo) |
| `:dead_letter` | `v1/schemas/dead_letter.json` | (nenhum) | 07, 5.2 e 6; bloco 09 | Vista `{ key, headers, payload }` da mensagem em `helpdesk.agent.dlq.v1`: `headers.dlq_source` (`broker`, `agent-mock`, `platform`), `headers.dlq_reason` (motivos permitidos por fonte), `headers.dlq_violations` (array decodificado do JSON do cabeçalho, com `pointer`, `type`, `message`; ao menos uma em `contrato` e `acao_invalida`), `headers.event_id` e `headers.traceparent` (texto, vazio quando ausente) e `payload` (o corpo original como texto, JSON ou não) |

Motivos da DLQ por fonte: `broker` → `contrato`, `event_id_divergente`, `traceparent_invalido`; `agent-mock` → `contrato` (evento de entrada), `acao_invalida` (ação própria); `platform` → `contrato` (inclui `conteudo_invalido` nas violações), `marca_divergente`, `turno_inexistente`. A mensagem do Kafka não tem envelope próprio: quem lê monta a vista e valida.

Cada ação leva o seu conteúdo (07, 5.3), por `if/then` no esquema:

| `action` | Exige | Opcional |
| --- | --- | --- |
| `reply` | `reply.text` (não vazio e não só espaços) | |
| `escalate` | `escalation.reason` e `escalation.summary` com os cinco campos da RN-39 | |
| `resolve` | `resolution.reason` (não só espaços) | `resolution.text` (mensagem de encerramento; se vier, não só espaços) |

`brand` em `agent_outbound` usa o mesmo formato de slug de `agent_inbound`. O consumer compara com a marca do atendimento: se divergir, DLQ sem efeito (ADR-014).

### Canais (07, 5.0; ADR-018)

Subconjunto fiel dos provedores: só os campos que o adaptador usa. Não têm campo `schema`; a versão vem do argumento `version:` (padrão `v1`). A marca e a conta nunca vêm do corpo, e sim da URL `/webhooks/:channel/:provider_account`.

| Contrato | Arquivo | Direção | Formato | Obrigatórios |
| --- | --- | --- | --- | --- |
| `:whatsapp_webhook` | `v1/schemas/channels/whatsapp.json` | entrada | Webhook da Cloud API da Meta | `object: "whatsapp_business_account"`, `entry[].id`, `entry[].changes[]` com `field: "messages"` e `value` com `messaging_product: "whatsapp"`, `metadata.display_phone_number`, `metadata.phone_number_id` e **ou** `messages[]` (`from`, `id`, `timestamp`, `type`; `text.body` quando `type` é `text`) **ou** `statuses[]` (`id`, `status` em `sent`/`delivered`/`read`/`failed`, `timestamp`, `recipient_id`). `contacts[]` (`wa_id`, `profile.name`) é opcional |
| `:email_push` | `v1/schemas/channels/email_push.json` | entrada | Push do Gmail no envelope do Pub/Sub | `message.data` (base64), `message.messageId`, `subscription`. `message.data` decodificado: `emailAddress` e `historyId` |
| `:email_history` | `v1/schemas/channels/email_history.json` | entrada | Gmail `users.history.list` | `historyId`. Opcional: `history[]` com `id` e `messagesAdded[].message` (`id`, `threadId`) |
| `:email_message` | `v1/schemas/channels/email_message.json` | entrada | Gmail `users.messages.get` (formato `full`) | `id`, `threadId`, `internalDate`, `payload.headers[]` com `From` e `Message-ID` (`To` e `Subject` opcionais); cada parte com `mimeType` e `body.size`. Anexo: parte com `filename`, `mimeType` e `body.size`, sem o arquivo |
| `:whatsapp_send_response` | `v1/schemas/channels/whatsapp_send_response.json` | entrada (resposta do envio) | Resposta de `POST /:phone_number_id/messages` | `messaging_product: "whatsapp"`, `contacts[]` (`input`, `wa_id`), `messages[]` com `id` (ao menos um). `messages[0].id` vira a `provider_message_id` |
| `:chat_webhook` | `v1/schemas/channels/chat.json` | entrada | Próprio do app | `message_id`, `account_id`, `customer_ref`, `text`, `sent_at` |
| `:chat_status` | `v1/schemas/channels/chat_status.json` | entrada (status) | Callback do app | `message_id`, `status` em `sent`/`delivered`/`read`/`failed`, `timestamp` (ISO 8601) |
| `:whatsapp_send` | `v1/schemas/channels/outbound/whatsapp.json` | saída | `POST /:phone_number_id/messages` | `messaging_product: "whatsapp"`, `to`, `type: "text"`, `text.body` (até 4.096 caracteres) |
| `:email_send` | `v1/schemas/channels/outbound/email.json` | saída | Gmail `users.messages.send` | `raw` (MIME em base64url), `threadId` |
| `:chat_send` | `v1/schemas/channels/outbound/chat.json` | saída | `POST /messages` do app | `customer_ref`, `text`. `reply_to` é opcional |

**Campo em base64 com JSON dentro.** No draft 2020-12, `contentSchema` é só anotação. Por isso o registro (`CONTRACTS[:email_push][:decoded]`) diz qual campo decodificar e contra qual `$defs` validar. O `contentSchema` continua no esquema como documentação. Erro no conteúdo decodificado sai com o pointer dentro do campo (`/message/data/historyId`). Base64 sem JSON válido sai como `conteudo_invalido`.

**Tipos de mensagem do WhatsApp.** `messages[].type` é texto livre (`text`, `image`, `reaction`, `interactive`...). Só `type: "text"` exige `text.body`. **Motivo:** um lote real pode misturar texto e imagem; rejeitar o tipo derrubaria o webhook inteiro, com as mensagens de texto junto. O adaptador decide o que fazer com cada tipo.

**Cabeçalhos do e-mail.** Só `From` e `Message-ID` são obrigatórios: `Message-ID` deduplica (vira `external_id`) e `From` identifica o cliente. `To` e `Subject` são opcionais, porque e-mail real pode vir sem eles e o 07 (5.1) trata o assunto como opcional. Os nomes são comparados sem diferenciar maiúsculas (RFC 5322): `message-id`, `Message-Id` e `MESSAGE-ID` valem. O adaptador deve fazer o mesmo ao ler `To` e `Subject`.

**Fora dos esquemas, no adaptador.** A janela de 24 h do WhatsApp depende do estado do atendimento. `Subject` com `Re:`, `In-Reply-To` e `References` ficam dentro do MIME de `raw`.

## Regex ECMA

O validador usa `regexp_resolver: "ecma"`, como manda o JSON Schema. **Motivo:** no resolvedor padrão (Ruby), `^` e `$` casam por linha, e `"infinitepay\njim"` passaria em `^[a-z0-9][a-z0-9_-]*$`. No ECMA, `^` e `$` ancoram o valor inteiro. Campos de texto livre que não podem ser só espaços usam `"pattern": "\\S"`.

## Violações

`HelpdeskContracts.errors` devolve `Violation(pointer, type, message)`. `pointer` é o JSON Pointer do dado. Campo obrigatório ausente gera uma violação por campo, com o pointer do próprio campo (`/brand`, `/reply/text`) e `type: "required"`, não o do objeto pai. Corpo bruto é lido como UTF-8, qualquer que seja a codificação marcada na `String` (corpo HTTP costuma chegar como `ASCII-8BIT` ou `US-ASCII`). UTF-8 inválido, no corpo ou em uma string de um `Hash`, vira `json_invalido`, sem exceção. Tipos próprios do validador: `json_invalido`, `schema_desconhecido`, `schema_de_outro_contrato` e `conteudo_invalido`. Os demais vêm do `json_schemer` (`enum`, `const`, `pattern`, `format`, `minLength`, `maxLength`, `contains`, `oneOf` etc.).

## Versão

A versão sai do campo `schema` (`helpdesk.<nome>.vN`). Os webhooks dos canais não têm esse campo e usam `version:` (padrão `v1`). Versão sem pasta, `schema` de outro contrato ou divergência entre o argumento e o campo geram uma violação (`schema_desconhecido` ou `schema_de_outro_contrato`).

Mudança incompatível cria `v2/` ao lado de `v1/`. `v1/` nunca é editada de forma incompatível (07, 5.4).

## Decisão: `additionalProperties` aberto

Nenhum esquema usa `additionalProperties: false`.

| Opção | Efeito |
| --- | --- |
| Fechado (`false`) | Um produtor que acrescenta um campo opcional quebra todo consumidor ainda na versão anterior. O evento iria para a DLQ e o caso escalaria (RN-45) por uma mudança que o 07 chama de compatível |
| **Aberto (escolhido)** | Campo novo opcional passa. É o que o 07, seção 5.4, pede: "consumidores ignoram campos desconhecidos" |

**Motivo.** Plataforma e agente são implantados por equipes diferentes, em momentos diferentes (07, 5.4). O que precisa ser fechado continua fechado por `enum` e `const`: `action` só aceita `reply`, `escalate` e `resolve` (RN-35), e `schema` só aceita a própria versão. Um campo extra como `refund: {...}` passa na validação, mas não tem efeito: o consumidor só lê os campos do contrato. A especificação de que isso continua assim está em `spec/schemas_spec.rb`.

## Fixtures

O nome da pasta é o nome do contrato (`v1/fixtures/valid/whatsapp_webhook/` testa `:whatsapp_webhook`). `spec/fixtures_spec.rb` gera um teste por arquivo.

- `valid/<contrato>/*.json` precisam passar sem nenhuma violação.
- `invalid/<contrato>/*.json` precisam falhar **pelo motivo esperado**. Cada pasta tem um `expected.yml` com o `pointer` e o `type` de cada arquivo:

```yaml
sem_brand.json: { pointer: "/brand", type: required }
reply_com_texto_vazio.json: { pointer: "/reply/text", type: minLength }
```

Quando a falha legítima gera mais de uma violação, o valor é uma lista:

```yaml
reply_com_texto_vazio.json:
  - { pointer: "/reply/text", type: minLength }
  - { pointer: "/reply/text", type: pattern }
```

O teste compara a lista **exata** de violações (nem mais, nem menos) e exige que as chaves do `expected.yml` sejam exatamente os arquivos da pasta. **Motivo:** uma fixture que só confere `valid? == false` passa mesmo quando falha por outro motivo (um campo esquecido, um erro de digitação) e deixa de provar a regra que deveria provar.

## Desenvolvimento

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Assinatura dos webhooks (`HelpdeskContracts::Signature`)

Faz parte do contrato, porque quem envia e quem recebe precisam calcular igual (07, seção 5.2; RNF-23; [ADR-019](../../docs/08-decisoes-de-arquitetura.md#adr-019--contas-dos-provedores-e-autenticação-dos-webhooks-de-entrada)). É usada pelo webhook plataforma → broker e pela entrada do chat do app.

```ruby
header = HelpdeskContracts::Signature.header(corpo_bruto, secret: segredo)  # "t=1763500000,v1=<hex>"
HelpdeskContracts::Signature.verify!(corpo_bruto, header, secret: segredo)  # true ou Signature::Invalid
```

- Cabeçalho `X-Helpdesk-Signature` (`HelpdeskContracts::Signature::HEADER`).
- `v1` é o HMAC-SHA256 de `"t.corpo_bruto"`. O horário entra no HMAC, então trocá-lo invalida a assinatura.
- Janela de ±5 min. A comparação é em tempo constante.
- `Invalid#reason`: `:ausente`, `:malformada`, `:fora_da_janela`, `:nao_confere` ou `:sem_segredo`.
- Confira sempre o **corpo bruto**, antes do parse do JSON.

