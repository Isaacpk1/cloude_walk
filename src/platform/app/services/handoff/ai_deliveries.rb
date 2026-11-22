# RN-38: a escalação cancela as saídas da IA que ainda não começaram. O marco é o commit do pedido de handoff (RN-34:
# "escala imediatamente"), não a execução do Escalate: sem isso, o job de uma resposta pendente entregaria a resposta
# entre o pedido e o aviso de transferência. Quem chama já travou o atendimento.
#
#   Handoff::AiDeliveries.cancel(ticket:, handoff_reason: "pedido_do_cliente")
#
# Só `pending`: uma saída em `sending` (chamada começou ou em conciliação) fica para a conciliação, e o aviso espera o
# resultado dela. No limite de trocas (RN-33, item 6), as respostas aplicadas saem antes do aviso; só o aviso de
# progresso cai. Um pedido explícito de humano gravado depois cancela as respostas mesmo assim (`kinds: ALL`).
module Handoff
  module AiDeliveries
    ALL = %w[reply resolution progress].freeze
    REASON = "handoff".freeze

    def self.kinds_for(handoff_reason) = handoff_reason == "limite_de_trocas" ? ALL - %w[reply] : ALL

    def self.cancel(ticket:, handoff_reason:, kinds: kinds_for(handoff_reason), now: Time.current)
      deliveries = Delivery.where(brand_id: ticket.brand_id, ticket_id: ticket.id, status: "pending", kind: kinds)
                           .where.not(ai_assignment_version: nil).order(:seq).to_a
      deliveries.each do |delivery|
        delivery.update!(status: "cancelled", lease_until: nil, last_error: REASON)
        OutboxEvent.where(brand_id: ticket.brand_id, dedup_key: "delivery:#{delivery.delivery_id}", completed_at: nil)
                   .update_all(completed_at: now, lease_until: nil, last_error: REASON)
        AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type: "delivery.cancelled",
                           trace_id: delivery.trace_id,
                           data: { delivery_id: delivery.delivery_id, seq: delivery.seq, reason: REASON, handoff_reason: })
      end
    end
  end
end
