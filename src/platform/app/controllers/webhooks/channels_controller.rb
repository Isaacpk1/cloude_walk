# Entrada dos provedores de canal (07, seções 3.1 e 5.0). Só traduz a requisição e chama os services.
# Herda de ActionController::API: o provedor não é um navegador, não tem sessão nem token CSRF.
module Webhooks
  class ChannelsController < ActionController::API
    ADAPTERS = { "chat" => ChannelAdapters::Chat }.freeze
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

      normalized = adapter.normalize(request.raw_post, account:, trace_id:, received_at: Time.current)
      # Só volta depois do commit: o 202 nunca confirma o que não foi gravado (invariante 1).
      result = Ingestion::Receive.call(normalized, provider_payload: JSON.parse(request.raw_post))

      render json: body_for(result), status: result.created? ? :accepted : :ok
    end

    private

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
