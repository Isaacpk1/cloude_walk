# Aviso de transferência ao cliente (RN-42; 07, seção 3.2), na transação de quem leva o caso a um humano: o
# Handoff::Escalate e a triagem que manda o caso novo direto para a fila humana (RN-33, item 3). Quem chama já
# travou o atendimento.
#
#   notice = Handoff::TransferNotice.call(ticket:, trace_id:, now:) # => Notice(delivery:, outbox_event_id:, context_until_seq:, context_version:) | nil
#
# Mensagem `system` com o próximo `seq`, no canal e na conta da última mensagem do cliente; entrega `handoff_notice`
# sem `ai_assignment_version` (nenhum cancelamento da IA o alcança) e `delivery.requested` no outbox. A ordem fica
# com o Deliveries::Send: uma saída anterior em `sending` segura o aviso (RN-38). Sem mensagem do cliente, nil.
module Handoff
  module TransferNotice
    DELIVERY_EVENT = "delivery.requested".freeze

    Notice = Data.define(:delivery, :outbox_event_id, :context_until_seq, :context_version)

    def self.call(ticket:, trace_id:, now: Time.current)
      origin = Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id, direction: "inbound", author_type: "customer")
                      .order(seq: :desc).first
      return unless origin

      seq = Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id).maximum(:seq).to_i + 1
      message = Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "system",
                                body: Handoff::Policy.for(ticket.brand).transfer_notice_text(ticket.brand.locale), seq:,
                                channel: origin.channel, provider_account: origin.provider_account, external_id: nil,
                                trace_id:, received_at: now)
      context_version = ticket.bump_context_version! # ADR-022: saída visível ao cliente
      delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                  provider_account: message.provider_account, kind: "handoff_notice", status: "pending",
                                  trace_id:).reload # delivery_id vem do padrão do banco
      item = OutboxEvent.create!(brand_id: ticket.brand_id, ticket:, event_type: DELIVERY_EVENT,
                                 dedup_key: "delivery:#{delivery.delivery_id}", trace_id:, next_attempt_at: now,
                                 payload: { delivery_id: delivery.delivery_id, ticket_id: ticket.id, seq: })
      Notice.new(delivery:, outbox_event_id: item.id, context_until_seq: origin.seq, context_version:)
    end
  end
end
