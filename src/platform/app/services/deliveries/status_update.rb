# Callback de status do provedor do chat (07, seção 5.0; interface do bloco 05, item 3).
#
#   Deliveries::StatusUpdate.call(account:, payload:) # => Result(status:, delivery:)
#
# A conta da URL define a marca: a entrega é procurada por (brand_id da conta, canal, conta,
# provider_message_id), então uma conta nunca alcança a entrega de outra marca (invariante 6).
# `failed` encerra a entrega como failed (delivery.failed, reason provider_failed); todo callback aceito
# registra delivery.status_received. Idempotente (RN-47): processed_events com uma chave derivada de
# (conta, message_id, status, timestamp), gravada na mesma transação do efeito (invariante 3). O mesmo
# callback repetido não muda nada nem audita de novo; message_id desconhecido não grava nada (nem
# processed_events) e o controller responde 503, para o provedor repetir depois da confirmação gravada.
module Deliveries
  class StatusUpdate
    Result = Data.define(:status, :delivery)
    CONSUMER = "chat_status".freeze
    # Namespace fixo do UUID v5 da chave de idempotência do callback.
    NAMESPACE = "9b0c6f3e-6a59-5b8e-9d1f-6f1d3c2a7b40".freeze

    def self.call(...) = new(...).call

    def initialize(account:, payload:)
      @account = account
      @payload = payload
    end

    def call
      delivery = find_delivery
      unless delivery
        JsonLog.warn("delivery.status_unknown", provider_account: @account.slug, brand_id: @account.brand_id,
                                                provider_message_id: message_id, status:)
        return Result.new(status: :unknown, delivery: nil)
      end

      ActiveRecord::Base.transaction do
        # Travas: processed_events e depois o atendimento, como o AgentActions::Apply (sem ciclo).
        next Result.new(status: :duplicate, delivery:) unless mark_processed

        Ticket.lock.find_by!(id: delivery.ticket_id, brand_id: delivery.brand_id)
        delivery.reload
        apply(delivery)
        Result.new(status: :accepted, delivery:)
      end
    end

    private

    def message_id = @payload.fetch("message_id")
    def status = @payload.fetch("status")
    def provider_timestamp = Time.iso8601(@payload.fetch("timestamp")).utc.iso8601(3)

    def find_delivery
      Delivery.find_by(brand_id: @account.brand_id, channel: @account.channel, provider_account: @account.slug,
                       provider_message_id: message_id)
    end

    def mark_processed
      key = Digest::UUID.uuid_v5(NAMESPACE, [ @account.id, message_id, status, @payload.fetch("timestamp") ].join("\n"))
      ProcessedEvent.insert({ consumer: CONSUMER, event_id: key }, returning: [ :event_id ]).rows.any?
    end

    def apply(delivery)
      audit(delivery, "delivery.status_received", provider_message_id: message_id, status:, provider_timestamp:)
      if status == "failed" && delivery.status != "failed"
        # O banco exige delivered_at só em delivered; a hora da confirmação continua na auditoria.
        delivery.update!(status: "failed", delivered_at: nil, lease_until: nil, last_error: "provider_failed")
        audit(delivery, "delivery.failed", attempt: delivery.attempts, reason: "provider_failed", http_status: nil,
                                           provider_timestamp:)
      end
      JsonLog.info("delivery.status_received", trace_id: delivery.trace_id, delivery_id: delivery.delivery_id,
                                               seq: delivery.seq, status: delivery.status, provider_status: status)
    end

    def audit(delivery, event_type, **data)
      AuditEvent.create!(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id, actor_type: "system", event_type:,
                         trace_id: delivery.trace_id, data: { delivery_id: delivery.delivery_id }.merge(data))
    end
  end
end
