# Adaptador de entrada do chat no app (RF-01, RF-05; 07, seção 5.0).
# Converte o webhook do provedor na mensagem normalizada (07, seção 5.1). O núcleo não conhece este formato.
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
  end
end
