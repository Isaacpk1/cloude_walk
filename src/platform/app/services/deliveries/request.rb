# Monta a requisição de uma saída para o provedor do chat (07, seção 5.0; interface do bloco 05, item 2).
# Só lê o banco: quem chama já está com o atendimento travado.
#
# - text: o corpo da mensagem de saída.
# - reply_to: o external_id da mensagem do cliente com seq = context_until_seq do turno aplicado, lido
#   da auditoria "delivery.requested" da entrega. Sem esse registro, a última mensagem do cliente antes
#   da saída.
# - customer_ref: o destino da resposta, que só existe no webhook cru do chat (messages.provider_payload)
#   da mensagem respondida; se ela não o tiver, a última mensagem do cliente antes da saída que o tenha.
#
# O corpo é validado contra o contrato chat_send (invariante 10). Fora do contrato, ou sem conta ou
# adaptador, `error` diz o motivo e nada é enviado: é falha definitiva (RN-44).
module Deliveries
  class Request
    Prepared = Data.define(:body, :secret, :error)

    def self.build(delivery) = new(delivery).build

    def initialize(delivery)
      @delivery = delivery
    end

    def build
      return failure("canal_sem_adaptador") unless @delivery.channel == "chat"

      account = ProviderAccount.find_by(brand_id: @delivery.brand_id, channel: @delivery.channel, slug: @delivery.provider_account)
      return failure("conta_inexistente") unless account

      message = Message.find_by!(id: @delivery.message_id, brand_id: @delivery.brand_id)
      replied = replied_message
      body = ChannelAdapters::Chat.outbound(customer_ref: customer_ref(replied), text: message.body, reply_to: replied&.external_id)
      return failure("fora_do_contrato_chat_send") unless HelpdeskContracts.valid?(:chat_send, body)

      Prepared.new(body: JSON.generate(body), secret: account.secret, error: nil)
    end

    private

    def failure(reason) = Prepared.new(body: nil, secret: nil, error: reason)

    def customer_messages
      Message.where(brand_id: @delivery.brand_id, ticket_id: @delivery.ticket_id, direction: "inbound", author_type: "customer")
             .where(seq: ...@delivery.seq)
    end

    def replied_message
      seq = AuditEvent.where(brand_id: @delivery.brand_id, ticket_id: @delivery.ticket_id, event_type: "delivery.requested")
                      .where("data->>'delivery_id' = ?", @delivery.delivery_id)
                      .pick(Arel.sql("data->>'context_until_seq'"))
      (seq && customer_messages.find_by(seq: seq.to_i)) || customer_messages.order(seq: :desc).first
    end

    def customer_ref(replied)
      ref = replied&.provider_payload&.dig("customer_ref")
      return ref if ref.present?

      customer_messages.where("provider_payload->>'customer_ref' IS NOT NULL").order(seq: :desc).first
                       &.provider_payload&.dig("customer_ref")
    end
  end
end
