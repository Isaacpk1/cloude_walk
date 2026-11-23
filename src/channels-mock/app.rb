require "roda"
require "helpdesk_contracts"
require_relative "lib/channels_mock/providers/chat"
require_relative "lib/channels_mock/platform_client"
require_relative "lib/channels_mock/inbox"
require_relative "lib/channels_mock/chat_sender"
require_relative "lib/channels_mock/clock"
require_relative "lib/channels_mock/faults"
require_relative "lib/channels_mock/chat_deliveries"
require_relative "lib/channels_mock/status_callbacks"
require_relative "lib/channels_mock/providers/chat_api"
require_relative "lib/channels_mock/conversation_view"
require_relative "lib/channels_mock/scenarios"
require_relative "lib/channels_mock/scenario_view"
require_relative "lib/channels_mock/agent_profile"

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
      # Lado do provedor: a plataforma entrega a resposta ao cliente (07, seção 5.0; RF-06).
      r.on "provider", "chat" do
        r.post "faults" do
          params = JSON.parse(r.body.read.then { _1.empty? ? "{}" : _1 })
          json_reply(200, Faults.set(params["fault"], times: params.fetch("times", 1)))
        rescue ArgumentError, TypeError, JSON::ParserError => e
          json_reply(422, { "error" => "falha_invalida", "details" => e.message })
        end

        # A tela marca a mensagem como lida ou simula a falha de entrega no aparelho do cliente.
        r.post "messages", String, "status" do |message_id|
          record = ChatDeliveries.find(message_id) || r.halt(404, "mensagem #{message_id} não encontrada")
          StatusCallbacks.enqueue(account: record.account, message_id:, status: r.params["status"].to_s)
          r.redirect "/"
        rescue HelpdeskContracts::InvalidPayload => e
          r.halt(422, e.message)
        end

        r.post String, "messages" do |account|
          reply = Providers::ChatApi.call(account:, raw_body: r.body.read, headers: provider_headers(r))
          json_reply(reply.status, reply.body, reply.headers)
        end
      end

      r.root do
        entries = Inbox.all
        items, orphans = ConversationView.build(entries:, records: ChatDeliveries.all)
        refresh = r.params["atualizar"].to_s[/\A[1-9]\d?\z/]
        view("index", locals: { items:, orphans:, accounts: Providers::Chat::ACCOUNTS, platform_url: PLATFORM_PUBLIC_URL,
                                last: entries.first, fault: Faults.state, refresh:,
                                scenarios: Scenarios.catalog, runs: Scenarios.runs.map(&:snapshot),
                                agent_profile: AgentProfile.view_state },
                      layout_opts: { locals: { refresh: } })
      end

      # Falha simulada do provedor do chat, escolhida na tela (blocos 05 e 09).
      r.post "simulador", "falhas" do
        Faults.set(r.params["fault"].to_s, times: r.params.fetch("times", "1").to_s.then { _1.empty? ? 1 : _1 })
        r.redirect "/"
      rescue ArgumentError, TypeError => e
        r.halt(422, e.message)
      end

      # Perfil do agente mock (bloco 08; RF-38, RN-46, RN-57): pela tela (formulário) ou por script (JSON).
      r.on "simulador", "agente", "perfil" do
        r.get true do
          json_reply(200, AgentProfile.state)
        rescue AgentProfile::Disabled, AgentProfile::Unavailable => e
          agent_profile_unavailable(e)
        end

        r.post true do
          json = r.content_type.to_s.start_with?("application/json")
          params = json ? JSON.parse(r.body.read.then { _1.empty? ? "{}" : _1 }) : r.params
          raise ArgumentError, "corpo precisa ser um objeto" unless params.is_a?(Hash)

          state = AgentProfile.set(scope: params["scope"], profile: params["profile"])
          next r.redirect("/#agente") unless json

          json_reply(200, state)
        rescue AgentProfile::UnknownProfile => e
          json_reply(422, { "error" => "perfil_desconhecido", "details" => e.message })
        rescue AgentProfile::UnknownScope => e
          json_reply(422, { "error" => "escopo_desconhecido", "details" => e.message })
        rescue AgentProfile::Disabled, AgentProfile::Unavailable => e
          agent_profile_unavailable(e)
        rescue ArgumentError, JSON::ParserError => e
          json_reply(422, { "error" => "pedido_invalido", "details" => e.message })
        end
      end

      # Cenários de rajada (bloco 06; RN-55, RN-56): pela tela (formulário) ou por script (JSON).
      r.on "simulador", "cenarios" do
        r.get Integer do |id|
          run = Scenarios.find(id) || r.halt(404, { "Content-Type" => "application/json" }, JSON.generate("error" => "execucao_nao_encontrada"))
          json_reply(200, run.snapshot)
        end

        r.post String do |name|
          json = r.content_type.to_s.start_with?("application/json")
          params = json ? JSON.parse(r.body.read.then { _1.empty? ? "{}" : _1 }) : r.params
          run = Scenarios.start(name, account: params["account"].to_s, account_id: params["account_id"].to_s,
                                      customer_ref: params["customer_ref"].to_s)
          next r.redirect("/?atualizar=1#cenarios") unless json

          json_reply(202, { "run_id" => run.id, "scenario" => run.scenario.name, "status" => run.snapshot["status"],
                            "status_url" => "/simulador/cenarios/#{run.id}" })
        rescue Scenarios::UnknownScenario => e
          json_reply(404, { "error" => "cenario_desconhecido", "details" => e.message })
        rescue HelpdeskContracts::InvalidPayload => e
          json_reply(422, { "error" => "contrato_invalido", "details" => e.message })
        rescue ArgumentError, JSON::ParserError => e
          json_reply(422, { "error" => "pedido_invalido", "details" => e.message })
        end
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

    def provider_headers(r)
      { HelpdeskContracts::Signature::HEADER => r.get_header("HTTP_X_HELPDESK_SIGNATURE"),
        "Idempotency-Key" => r.get_header("HTTP_IDEMPOTENCY_KEY"),
        "X-Conversation-Id" => r.get_header("HTTP_X_CONVERSATION_ID"),
        "X-Conversation-Seq" => r.get_header("HTTP_X_CONVERSATION_SEQ"),
        "traceparent" => r.get_header("HTTP_TRACEPARENT") }
    end

    def json_reply(status, body, headers = {})
      response.status = status
      response["Content-Type"] = "application/json"
      headers.each { |name, value| response[name] = value }
      JSON.generate(body)
    end

    def agent_profile_unavailable(error)
      code = error.is_a?(AgentProfile::Disabled) ? "controle_desligado" : "controle_indisponivel"
      json_reply(503, { "error" => code, "details" => error.message })
    end

    def send_chat(account, params)
      ChatSender.call(client: CLIENT, account:, fields: params, tamper_signature: params["tamper_signature"] == "1")
    end

    def deliver(account, payload) = ChatSender.deliver(client: CLIENT, account:, payload:)
  end
end
