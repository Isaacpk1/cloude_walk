FactoryBot.define do
  # Ação "turn.dispatch" que o scheduler grava no outbox quando dispatch_due_at vence (07, seção 3.4;
  # ADR-016). O formato segue a interface do bloco 03: chave pelo atendimento, pela atribuição e pela
  # última mensagem a cobrir.
  factory :turn_dispatch, class: "OutboxEvent" do
    transient do
      for_ticket { nil }
      assignment_version { for_ticket.assignment_version }
      cover_until_seq { for_ticket.latest_customer_seq }
      dispatch_due_at { for_ticket.dispatch_due_at || Time.current }
    end

    brand_id { for_ticket.brand_id }
    ticket { for_ticket }
    event_type { "turn.dispatch" }
    dedup_key { "turn.dispatch:#{for_ticket.id}:#{assignment_version}:#{cover_until_seq}" }
    payload do
      { "ticket_id" => for_ticket.id, "assignment_version" => assignment_version, "cover_until_seq" => cover_until_seq,
        "dispatch_due_at" => dispatch_due_at.utc.iso8601(3) }
    end
    trace_id { for_ticket.messages.find_by(seq: cover_until_seq)&.trace_id || SecureRandom.hex(16) }
    next_attempt_at { Time.current }
  end
end
