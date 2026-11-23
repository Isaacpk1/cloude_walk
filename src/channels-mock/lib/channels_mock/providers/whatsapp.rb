require "securerandom"
require "json"
require "helpdesk_contracts"
require_relative "../clock"
require_relative "../faults"
require_relative "../platform_client"

module ChannelsMock
  module Providers
    # WhatsApp no formato da Cloud API da Meta (07, seção 5.0; ADR-018). Entrada: monta o webhook com uma mensagem de texto.
    # Saída: POST /provider/whatsapp/:conta/:phone_number_id/messages, assinado, com Idempotency-Key; repetir a chave
    # devolve a mesma confirmação sem registrar de novo.
    module Whatsapp
      ACCOUNTS = { "infinitepay-whatsapp-mock" => "100000000000001", "jim-whatsapp-mock" => "100000000000002" }.freeze
      Sent = Data.define(:id, :account, :to, :text, :key, :received_at)

      @lock = Mutex.new
      @sent = []
      @by_key = {}

      module_function

      def webhook(account:, from:, text:, id: nil, sent_at: Clock.now)
        payload = {
          "object" => "whatsapp_business_account",
          "entry" => [ { "id" => "102290129340398", "changes" => [ { "field" => "messages", "value" => {
            "messaging_product" => "whatsapp",
            "metadata" => { "display_phone_number" => "5511300000#{ACCOUNTS.keys.index(account).to_i + 1}", "phone_number_id" => ACCOUNTS.fetch(account) },
            "contacts" => [ { "wa_id" => from } ],
            "messages" => [ { "from" => from, "id" => id.to_s.empty? ? "wamid.#{SecureRandom.hex(10)}" : id,
                              "timestamp" => sent_at.to_i.to_s, "type" => "text", "text" => { "body" => text } } ]
          } } ] } ]
        }
        HelpdeskContracts.validate!(:whatsapp_webhook, payload)
      end

      # Devolve [status, corpo]. A falha 503 simulada vem do módulo Faults, antes de qualquer efeito.
      def receive(account:, phone_number_id:, raw_body:, signature:, key:)
        return [ 404, { "error" => "conta_desconhecida" } ] unless ACCOUNTS[account] == phone_number_id
        return [ 503, { "error" => "provedor_indisponivel" } ] if Faults.take(:unavailable)

        HelpdeskContracts::Signature.verify!(raw_body, signature, secret: PlatformClient.secret_for(account), now: Clock.now)
        return [ 400, { "error" => "idempotency_key_ausente" } ] if key.to_s.strip.empty?

        body = JSON.parse(raw_body)
        HelpdeskContracts.validate!(:whatsapp_send, body)
        reply = @lock.synchronize do
          @by_key[[ account, key ]] ||= begin
            id = "wamid.OUT#{SecureRandom.hex(8)}"
            @sent.unshift(Sent.new(id:, account:, to: body["to"], text: body.dig("text", "body"), key:, received_at: Clock.now))
            { "messaging_product" => "whatsapp", "contacts" => [ { "input" => body["to"], "wa_id" => body["to"] } ], "messages" => [ { "id" => id } ] }
          end
        end
        [ 200, reply ]
      rescue HelpdeskContracts::Signature::Invalid => e
        [ 401, { "error" => "assinatura_invalida", "reason" => e.reason.to_s } ]
      rescue JSON::ParserError, HelpdeskContracts::InvalidPayload => e
        [ 422, { "error" => "contrato_invalido", "details" => e.message } ]
      end

      def sent = @lock.synchronize { @sent.dup }
      def clear = @lock.synchronize { @sent.clear && @by_key.clear }
    end
  end
end
