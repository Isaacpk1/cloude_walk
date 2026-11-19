# Evento `helpdesk.agent_event.v1` de um turno (07, seção 5.2). Os IDs expostos ao agente têm
# prefixo (`tkt_`, `cus_`, `msg_`), como nos exemplos do contrato.
module Turns
  class Envelope
    AUTHORS = { "customer" => "customer", "bot" => "bot", "analyst" => "analyst", "system" => "system" }.freeze

    def initialize(ticket:, event_id:, turn:, pending:, history:, deadline_at:)
      @ticket = ticket
      @event_id = event_id
      @turn = turn
      @pending = pending
      @history = history
      @deadline_at = deadline_at
    end

    def to_h
      latest = @pending.last
      {
        "schema" => "helpdesk.agent_event.v1", "event_id" => @event_id, "event_type" => "message.created",
        "occurred_at" => iso(Time.current), "conversation_id" => self.class.conversation_id(@ticket),
        "brand" => @ticket.brand.slug, "locale" => @ticket.brand.locale, "ticket" => ticket_data,
        "customer" => customer_data, "message" => { "id" => "msg_#{latest.id}", "seq" => latest.seq, "text" => latest.body },
        "context" => {
          "pending_messages" => @pending.map { { "seq" => _1.seq, "text" => _1.body } },
          "history" => @history.map { { "seq" => _1.seq, "author" => AUTHORS.fetch(_1.author_type), "text" => _1.body } }
        },
        "turn" => @turn, "context_until_seq" => @ticket.latest_customer_seq,
        "assignment_version" => @ticket.assignment_version, "deadline_at" => iso(@deadline_at)
      }
    end

    def self.conversation_id(ticket) = "tkt_#{ticket.id}"

    private

    def ticket_data
      { "state" => @ticket.state, "channel" => @ticket.channel, "category" => @ticket.category,
        "priority" => @ticket.priority, "queue" => @ticket.queue&.id&.to_s,
        "ai_turns" => @ticket.ai_turns.where(status: "applied").count }.compact
    end

    def customer_data
      customer = @ticket.customer
      { "id" => "cus_#{customer.id}", "verified" => customer.verified, "display_name" => customer.display_name }
    end

    def iso(time) = time.utc.iso8601(3)
  end
end
