# Callback de status de entrega do chat do app (07, seção 5.0; interface do bloco 05, item 3).
# Autentica a assinatura da conta antes de ler o corpo (RNF-23, ADR-019), valida o contrato chat_status
# (invariante 10) e delega ao Deliveries::StatusUpdate. 202 para aceito, repetido ou desconhecido: o
# provedor não tem o que corrigir nesses casos e não deve repetir.
module Webhooks
  class ChatStatusesController < ActionController::API
    DATABASE_DOWN = ChannelsController::DATABASE_DOWN

    rescue_from ProviderAccount::NotFound do |error|
      render json: { status: "not_found", error: error.message }, status: :not_found
    end

    rescue_from HelpdeskContracts::InvalidPayload do |error|
      render json: { status: "invalid", error: "payload fora do contrato #{error.contract}",
                     violations: error.violations.map(&:to_h) }, status: :unprocessable_content
    end

    rescue_from HelpdeskContracts::Signature::Invalid do |error|
      JsonLog.warn("webhook.status_unauthorized", reason: error.reason, provider_account: request.path_parameters[:provider_account])
      render json: { status: "unauthorized", reason: error.reason }, status: :unauthorized
    end

    rescue_from(*DATABASE_DOWN) do
      response.set_header("Retry-After", "5")
      render json: { status: "unavailable" }, status: :service_unavailable
    end

    def create
      account = ProviderAccount.find!(channel: "chat", slug: request.path_parameters[:provider_account])
      HelpdeskContracts::Signature.verify!(request.raw_post, request.headers[HelpdeskContracts::Signature::HEADER],
                                           secret: account.secret)
      payload = JSON.parse(HelpdeskContracts.validate!(:chat_status, request.raw_post))

      result = Deliveries::StatusUpdate.call(account:, payload:)
      render json: { status: result.status.to_s }, status: :accepted
    end
  end
end
