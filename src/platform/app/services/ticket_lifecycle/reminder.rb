module TicketLifecycle
  module Reminder
    TEXTS = { "pt-BR" => "Você ainda precisa de ajuda? Se precisar, responda por aqui.",
              "en" => "Do you still need help? Reply here if you do." }.freeze

    # A entrega mantém a mesma ordem e idempotência do canal. Nenhuma chamada externa nesta transação.
    def self.call(ticket:, trace_id:, now:)
      origin = ticket.messages.where(brand_id: ticket.brand_id, direction: "inbound").order(seq: :desc).first!
      seq = ticket.messages.maximum(:seq).to_i + 1
      message = Message.create!(brand_id: ticket.brand_id, ticket:, channel: origin.channel,
                                provider_account: origin.provider_account, direction: "outbound", author_type: "system",
                                body: TEXTS.fetch(ticket.brand.locale), seq:, trace_id:, received_at: now)
      ticket.bump_context_version!
      delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, channel: origin.channel,
                                  provider_account: origin.provider_account, seq:, trace_id:, kind: "reminder", status: "pending").reload
      event = OutboxEvent.create!(brand_id: ticket.brand_id, ticket:, event_type: "delivery.requested",
                                  dedup_key: "delivery:#{delivery.delivery_id}", trace_id:, next_attempt_at: now,
                                  payload: { delivery_id: delivery.delivery_id, ticket_id: ticket.id, seq: })
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type: "delivery.requested", trace_id:,
                         data: { delivery_id: delivery.delivery_id, seq:, kind: "reminder" })
      event.id
    end
  end
end
