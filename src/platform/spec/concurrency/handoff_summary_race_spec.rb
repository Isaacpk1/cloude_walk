require "rails_helper"

# Resumo do handoff com processos concorrentes, no Postgres de verdade e fora da transação de teste (AGENTS.md,
# item 3; RN-39, RN-40; invariantes 3 e 8).
RSpec.describe "RN-39, RN-40: resumo do handoff com workers concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def escalated_ticket
    turn = opened_turn
    AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
    ingest("ainda não caiu")
    ticket = turn.ticket.reload
    Handoff::Escalate.call(request_handoff(ticket, reason: "prazo_do_turno", source: "scheduler"))
    ticket.reload
  end

  def summary_item(ticket)
    # O Escalate (bloco 10) já grava este item; o teste o regrava com o payload que controla.
    OutboxEvent.where(dedup_key: "summary:#{ticket.id}:0").delete_all
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: Handoff::Summarize::EVENT_TYPE,
                        dedup_key: "summary:#{ticket.id}:0", trace_id: "d" * 32, next_attempt_at: Time.current,
                        payload: { "ticket_id" => ticket.id, "from_assignment_version" => 0, "reason" => "prazo_do_turno",
                                   "escalated_at" => Time.current.utc.iso8601(6) })
  end

  it "o mesmo item em quatro workers ao mesmo tempo grava um resumo e uma auditoria" do
    ticket = escalated_ticket
    item = summary_item(ticket)

    results = run_concurrently(threads: 4) { Handoff::Summarize.call(item.id) }
    raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

    expect(results.map(&:status).tally).to eq(available: 1, already_done: 3)
    expect(HandoffSummary.where(ticket_id: ticket.id).count).to eq(1)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "handoff.summary_available").count).to eq(1)
  end

  it "o resumo da plataforma e o do agente ao mesmo tempo: fica um só, sem erro" do
    ticket = escalated_ticket
    item = summary_item(ticket)
    agent_fields = HandoffSummary::FIELDS.index_with { "do agente" }

    results = run_concurrently(threads: 2) do |i|
      if i.zero?
        Handoff::Summarize.call(item.id)
      else
        # Como o Escalate grava o resumo do agente: com o atendimento travado e ON CONFLICT DO NOTHING.
        ActiveRecord::Base.transaction do
          Ticket.lock.find(ticket.id)
          HandoffSummary.insert_all([ { brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: 0, source: "agent",
                                        status: "available", fields: agent_fields, trace_id: "a" * 32 } ],
                                    unique_by: %i[ticket_id from_assignment_version])
        end
      end
    end
    raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

    summary = HandoffSummary.where(ticket_id: ticket.id).sole
    expect(results.first.status).to eq(summary.source == "platform" ? :available : :already_present)
    expect(item.reload.completed_at).to be_present
    expect(ticket.reload.state).to eq("aguardando_humano")
  end
end
