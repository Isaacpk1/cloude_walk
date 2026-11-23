# Entrada dos provedores de canal (07, seções 3.1 e 5.0). Só traduz a requisição e chama os services.
# Herda de ActionController::API: o provedor não é um navegador, não tem sessão nem token CSRF.
module Webhooks
  class ChannelsController < ActionController::API
    ADAPTERS = { "chat" => ChannelAdapters::Chat, "whatsapp" => ChannelAdapters::Whatsapp, "email" => ChannelAdapters::Email }.freeze
    TRACEPARENT = /\A00-(?<trace_id>\h{32})-\h{16}-\h{2}\z/
    DATABASE_DOWN = [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::DatabaseConnectionError ].freeze

    rescue_from ProviderAccount::NotFound, ActiveRecord::RecordNotFound do |error|
      render json: { status: "not_found", error: error.message }, status: :not_found
    end

    # RN-44: fora do contrato é falha permanente. 4xx para o provedor não repetir.
    rescue_from HelpdeskContracts::InvalidPayload do |error|
      render json: { status: "invalid", error: "payload fora do contrato #{error.contract}",
                     violations: error.violations.map(&:to_h) }, status: :unprocessable_content
    end

    # ADR-019: o corpo é de outra conta do provedor que não a da URL.
    rescue_from ChannelAdapters::Rejected do |error|
      render json: { status: "invalid", error: error.message }, status: :unprocessable_content
    end

    # E-mail: a API do provedor não respondeu ao buscar o histórico. Nada foi gravado; o push é reenviado.
    rescue_from ChannelAdapters::GmailClient::Unavailable do
      response.set_header("Retry-After", "5")
      render json: { status: "unavailable" }, status: :service_unavailable
    end

    # RNF-23, ADR-019: sem a assinatura da conta, nada é lido nem gravado.
    rescue_from HelpdeskContracts::Signature::Invalid do |error|
      Rails.logger.warn("webhook recusado: assinatura #{error.reason} conta=#{request.path_parameters[:provider_account]}")
      render json: { status: "unauthorized", reason: error.reason }, status: :unauthorized
    end

    # RNF-14, RNF-19: sem banco, nada é confirmado. O provedor tenta de novo (07, seção 6).
    rescue_from(*DATABASE_DOWN) do
      response.set_header("Retry-After", "5")
      render json: { status: "unavailable" }, status: :service_unavailable
    end

    def create
      # path_parameters: o corpo é lido cru pelo adaptador. JSON malformado vira 422 do contrato, não erro do Rails.
      route = request.path_parameters
      account = ProviderAccount.find!(channel: route[:channel], slug: route[:provider_account])
      adapter = ADAPTERS.fetch(account.channel) { raise ProviderAccount::NotFound, "canal #{account.channel} ainda sem adaptador" }
      # Antes do contrato: corpo de quem não tem o segredo da conta nem chega ao parser.
      HelpdeskContracts::Signature.verify!(request.raw_post, request.headers[HelpdeskContracts::Signature::HEADER],
                                           secret: account.secret)
      response.set_header("X-Trace-Id", trace_id)

      return render_email(account) if account.channel == "email"

      parsed = adapter.normalize(request.raw_post, account:, trace_id:, received_at: Time.current)
      return render_batch(parsed, account) if parsed.is_a?(ChannelAdapters::Whatsapp::Parsed)

      # Só volta depois do commit: o 202 nunca confirma o que não foi gravado (invariante 1).
      result = Ingestion::Receive.call(parsed, provider_payload: JSON.parse(request.raw_post))

      render json: body_for(result), status: result.created? ? :accepted : :ok
    end

    private

    # Webhook em lote (WhatsApp): cada mensagem de texto é uma transação de ingestão; cada uma guarda o seu pedaço cru
    # do webhook (messages[]), que é de onde a resposta tira o telefone do cliente. Sem mensagens (só status), 200.
    def render_batch(parsed, _account)
      raw = JSON.parse(request.raw_post)
      raw_messages = raw["entry"].flat_map { |entry| entry["changes"].flat_map { Array(_1.dig("value", "messages")) } }.index_by { _1["id"] }
      results = parsed.messages.map do |normalized|
        Ingestion::Receive.call(normalized, provider_payload: raw_messages.fetch(normalized["external_id"]))
      end
      status = results.any?(&:created?) ? :accepted : :ok
      render json: { status: results.empty? ? "ignored" : (status == :accepted ? "accepted" : "duplicate"),
                     messages: results.map { |r| { message_id: r.message.id, ticket_id: r.ticket.id, seq: r.message.seq, created: r.created? } },
                     unsupported: parsed.unsupported, trace_id: }, status:
    end

    # E-mail: o push só avisa; o adaptador busca as mensagens novas e cada uma é uma ingestão. O cursor do histórico só
    # avança depois de todas gravadas (o push reenviado repete as que já entraram, que a deduplicação absorve).
    def render_email(account)
      parsed = ChannelAdapters::Email.fetch(request.raw_post, account:, trace_id:, received_at: Time.current)
      results = parsed.messages.map { Ingestion::Receive.call(_1, provider_payload: parsed.raw.fetch(_1["external_id"])) }
      account.update_columns(history_id: parsed.history_id, updated_at: Time.current) if parsed.history_id > account.history_id.to_i
      created = results.any?(&:created?)
      render json: { status: results.empty? ? "ignored" : (created ? "accepted" : "duplicate"),
                     messages: results.map { |r| { message_id: r.message.id, ticket_id: r.ticket.id, seq: r.message.seq, created: r.created? } },
                     trace_id: }, status: created ? :accepted : :ok
    end

    # RF-56: propaga o trace do W3C Trace Context; sem ele, a plataforma inicia um.
    def trace_id
      @trace_id ||= TRACEPARENT.match(request.headers["traceparent"].to_s)&.[](:trace_id) || SecureRandom.hex(16)
    end

    def body_for(result)
      { status: result.created? ? "accepted" : "duplicate", message_id: result.message.id,
        ticket_id: result.ticket.id, seq: result.message.seq, trace_id: result.message.trace_id }
    end
  end
end
