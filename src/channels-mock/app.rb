require "roda"
require "helpdesk_contracts"
require_relative "lib/channels_mock/providers/chat"
require_relative "lib/channels_mock/platform_client"
require_relative "lib/channels_mock/inbox"

module ChannelsMock
  # Provedores simulados e simulador do cliente (RF-04, ADR-012). Bloco 02: só o chat do app, na entrada.
  class App < Roda
    PLATFORM_URL = ENV.fetch("PLATFORM_URL", "http://localhost:3000")
    PLATFORM_PUBLIC_URL = ENV.fetch("PLATFORM_PUBLIC_URL", "http://localhost:3000")

    # UTF-8 explícito: contêineres costumam rodar com locale C.
    plugin :render, escape: true, views: File.expand_path("views", __dir__), template_opts: { default_encoding: "UTF-8" }
    plugin :all_verbs
    plugin :halt

    # Definido antes do freeze do config.ru; os testes trocam pelo WebMock, não pelo cliente.
    CLIENT = PlatformClient.new(base_url: PLATFORM_URL)

    route do |r|
      r.root do
        view("index", locals: { entries: Inbox.all, accounts: Providers::Chat::ACCOUNTS, platform_url: PLATFORM_PUBLIC_URL,
                                last: Inbox.all.first })
      end

      r.on "chat", "messages" do
        r.post true do
          account = r.params["account"].to_s
          r.halt(422, "conta desconhecida: #{account}") unless Providers::Chat::ACCOUNTS.include?(account)

          send_chat(account, r.params)
          r.redirect "/"
        end

        # Reenvia o mesmo corpo, com o mesmo message_id: o provedor reentregando o webhook (RNF-15).
        r.post Integer, "resend" do |id|
          entry = Inbox.find(id) || r.halt(404, "envio #{id} não encontrado")
          deliver(entry.account, entry.payload)
          r.redirect "/"
        end
      end
    end

    private

    def send_chat(account, params)
      payload = Providers::Chat.webhook(account_id: params["account_id"].to_s, customer_ref: params["customer_ref"].to_s,
                                        text: params["text"].to_s, message_id: params["message_id"].to_s)
      deliver(account, payload, tamper_signature: params["tamper_signature"] == "1")
    rescue HelpdeskContracts::InvalidPayload => e
      Inbox.add(channel: "chat", account:, payload: params.slice("account_id", "customer_ref", "text", "message_id"),
                response: nil, error: e.message)
    end

    def deliver(account, payload, tamper_signature: false)
      response = CLIENT.deliver(channel: "chat", account:, payload:, tamper_signature:)
      Inbox.add(channel: "chat", account:, payload:, response:, error: nil, tampered: tamper_signature)
    end
  end
end
