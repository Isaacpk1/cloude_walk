# Adaptador do chat no app (RF-01, RF-05, RF-06; 07, seção 5.0).
# Entrada: converte o webhook do provedor na mensagem normalizada (07, seção 5.1). Saída: monta o corpo
# do POST /messages (contrato chat_send). O núcleo não conhece estes formatos.
module ChannelAdapters
  module Chat
    module_function

    # Valida o webhook e a saída contra os contratos (invariante 10). Fora do contrato: InvalidPayload (RN-44).
    def normalize(raw_body, account:, trace_id:, received_at:)
      webhook = JSON.parse(HelpdeskContracts.validate!(:chat_webhook, raw_body))
      normalized = {
        "schema" => "helpdesk.normalized_message.v1",
        "channel" => "chat",
        "brand" => account.brand_slug,
        "provider_account" => account.slug,
        "external_id" => webhook.fetch("message_id"),
        "sender" => { "channel_identity" => webhook.fetch("account_id") },
        "content" => { "type" => "text", "text" => webhook.fetch("text") },
        "received_at" => received_at.utc.iso8601(3),
        "trace_id" => trace_id
      }
      HelpdeskContracts.validate!(:normalized_message, normalized)
    end

    # Corpo do envio (07, seção 5.0: customer_ref, text e reply_to opcional). Quem chama valida contra o
    # contrato chat_send antes de enviar (invariante 10); a ordem das chaves é fixa, para o corpo ser o
    # mesmo em toda retentativa.
    def outbound(customer_ref:, text:, reply_to:)
      { "customer_ref" => customer_ref, "text" => text, "reply_to" => reply_to }.compact
    end
  end
end
