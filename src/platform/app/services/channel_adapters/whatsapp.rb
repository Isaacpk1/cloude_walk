# Adaptador do WhatsApp, no formato da Cloud API da Meta (RF-02, RF-05, RF-06; 07, seção 5.0; ADR-018).
# Entrada: um webhook traz várias mensagens e statuses. As de texto viram mensagens normalizadas (07, seção 5.1); as de
# outro tipo (imagem, áudio, reação) são válidas no contrato, mas não são processadas: voltam em `unsupported`, para o
# lote não ir inteiro para a DLQ. O `metadata.phone_number_id` do corpo precisa ser o número da conta da URL.
module ChannelAdapters
  # O provedor mandou algo que a plataforma recusa e que repetir não conserta: 422, nada é gravado (RN-44).
  Rejected = Class.new(StandardError)
  # O corpo diz que é de outra conta do provedor que não a da URL (ADR-019).
  AccountMismatch = Class.new(Rejected)
  # Mensagem sem o que a normalização exige (remetente, Message-ID).
  InvalidMessage = Class.new(Rejected)

  module Whatsapp
    Parsed = Data.define(:messages, :unsupported)

    module_function

    def normalize(raw_body, account:, trace_id:, received_at:)
      webhook = JSON.parse(HelpdeskContracts.validate!(:whatsapp_webhook, raw_body))
      messages = []
      unsupported = []
      webhook.fetch("entry").each do |entry|
        entry.fetch("changes").each do |change|
          value = change.fetch("value")
          check_account!(value, account)
          Array(value["messages"]).each do |raw|
            if raw["type"] == "text"
              messages << normalized(raw, account:, trace_id:, received_at:)
            else
              unsupported << { "id" => raw["id"], "type" => raw["type"] }
            end
          end
        end
      end
      Parsed.new(messages:, unsupported:)
    end

    # Corpo do envio (POST /:phone_number_id/messages): `to` é o telefone do cliente (wa_id).
    def outbound(to:, text:)
      { "messaging_product" => "whatsapp", "to" => to, "type" => "text", "text" => { "body" => text } }
    end

    def check_account!(value, account)
      number = value.dig("metadata", "phone_number_id")
      return if number == account.phone_number_id

      raise AccountMismatch, "phone_number_id #{number} não é da conta #{account.slug}"
    end

    def normalized(raw, account:, trace_id:, received_at:)
      message = {
        "schema" => "helpdesk.normalized_message.v1", "channel" => "whatsapp", "brand" => account.brand_slug,
        "provider_account" => account.slug, "external_id" => raw.fetch("id"),
        "sender" => { "channel_identity" => raw.fetch("from") },
        "content" => { "type" => "text", "text" => raw.dig("text", "body") },
        "received_at" => received_at.utc.iso8601(3), "trace_id" => trace_id
      }
      HelpdeskContracts.validate!(:normalized_message, message)
    end
  end
end
