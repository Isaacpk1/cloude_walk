require_relative "inbox"
require_relative "providers/chat"

module ChannelsMock
  # Caminho único de envio do cliente pelo chat: monta o webhook no contrato, assina e entrega à
  # plataforma, e guarda no histórico do simulador. Usado pelo formulário e pelos cenários de rajada.
  module ChatSender
    FIELDS = %w[account_id customer_ref text message_id].freeze

    module_function

    # Devolve a entrada do Inbox. Fora do contrato, guarda o erro e não chama a plataforma.
    def call(client:, account:, fields:, tamper_signature: false)
      payload = Providers::Chat.webhook(account_id: fields["account_id"].to_s, customer_ref: fields["customer_ref"].to_s,
                                        text: fields["text"].to_s, message_id: fields["message_id"].to_s)
      deliver(client:, account:, payload:, tamper_signature:)
    rescue HelpdeskContracts::InvalidPayload => e
      Inbox.add(channel: "chat", account:, payload: fields.slice(*FIELDS), response: nil, error: e.message)
    end

    def deliver(client:, account:, payload:, tamper_signature: false)
      response = client.deliver(channel: "chat", account:, payload:, tamper_signature:)
      Inbox.add(channel: "chat", account:, payload:, response:, error: nil, tampered: tamper_signature)
    end
  end
end
