# Grava direto no banco a saída e a entrega no formato combinado do bloco 05 (interface entre S1, S2 e
# S4), para testar a leitura do painel sem o AgentActions::Apply e o Deliveries::Send:
# - record_outbound: o que a aplicação da ação grava na mesma transação do applied (mensagem outbound,
#   deliveries pending, outbox delivery.requested e auditoria delivery.requested);
# - record_delivery_*: a auditoria e o estado que o envio ao provedor e o callback de status gravam.
# As auditorias levam occurred_at = Time.current, para as durações seguirem o tempo controlado do teste.
module DeliveryRecordHelpers
  def record_outbound(turn, text: "Seu repasse cai hoje até as 18h.", kind: "reply")
    ticket = turn.ticket.reload
    last_customer = ticket.messages.where(direction: "inbound", author_type: "customer").order(:seq).last
    trace_id = OutboxEvent.find_by(id: turn.event_id)&.trace_id || SecureRandom.hex(16)
    seq = ticket.messages.maximum(:seq).to_i + 1
    message = Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "bot", body: text,
                              seq:, channel: last_customer.channel, provider_account: last_customer.provider_account,
                              external_id: nil, trace_id:, received_at: Time.current)
    delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                provider_account: message.provider_account, kind:, status: "pending",
                                ai_assignment_version: turn.assignment_version, trace_id:)
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "delivery.requested",
                        dedup_key: "delivery:#{delivery.delivery_id}",
                        payload: { "delivery_id" => delivery.delivery_id, "ticket_id" => ticket.id, "seq" => seq },
                        trace_id:, next_attempt_at: Time.current)
    delivery_audit(delivery, "delivery.requested",
                   "message_id" => message.id, "seq" => seq, "kind" => kind, "turn" => turn.turn,
                   "context_until_seq" => turn.context_until_seq)
    delivery
  end

  def record_delivery_sending(delivery, attempt: 1)
    delivery.update_columns(status: "sending", attempts: attempt, lease_until: 30.seconds.from_now)
    delivery_audit(delivery, "delivery.sending", "seq" => delivery.seq, "attempt" => attempt)
  end

  def record_delivery_delivered(delivery, attempt: 1, duration_ms: 180, provider_message_id: "pmsg_#{SecureRandom.hex(4)}",
                                replayed: false)
    delivery.update_columns(status: "delivered", provider_message_id:, delivered_at: Time.current, lease_until: nil)
    delivery_audit(delivery, "delivery.delivered", "seq" => delivery.seq, "attempt" => attempt,
                                                   "provider_message_id" => provider_message_id,
                                                   "duration_ms" => duration_ms, "replayed" => replayed)
  end

  def record_delivery_retry(delivery, attempt: 1, error: "503 falha simulada", next_attempt_at: 2.seconds.from_now)
    delivery.update_columns(status: "pending", last_error: error, lease_until: nil)
    delivery_audit(delivery, "delivery.retry_scheduled", "attempt" => attempt, "error" => error,
                                                         "next_attempt_at" => next_attempt_at.utc.iso8601(3))
  end

  def record_delivery_failed(delivery, attempt: 1, reason: "seq_anterior", http_status: 409)
    delivery.update_columns(status: "failed", last_error: reason, lease_until: nil)
    delivery_audit(delivery, "delivery.failed", "attempt" => attempt, "reason" => reason, "http_status" => http_status)
  end

  def record_reconciliation_needed(delivery, attempts: delivery.attempts)
    delivery_audit(delivery, "delivery.reconciliation_needed", "attempts" => attempts)
  end

  def record_status_received(delivery, status: "read", provider_timestamp: Time.current)
    delivery_audit(delivery, "delivery.status_received", "provider_message_id" => delivery.provider_message_id,
                                                         "status" => status,
                                                         "provider_timestamp" => provider_timestamp.utc.iso8601(3))
  end

  private

  def delivery_audit(delivery, event_type, data)
    AuditEvent.create!(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id, actor_type: "system", event_type:,
                       data: { "delivery_id" => delivery.delivery_id }.merge(data), trace_id: delivery.trace_id,
                       occurred_at: Time.current)
  end
end

RSpec.configure { |c| c.include DeliveryRecordHelpers }
