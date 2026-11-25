require "rails_helper"

RSpec.describe "RN-07, RN-08, RN-47: ciclo de vida concorrente", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def resolved_case
    turn = opened_turn("funcionou")
    action = agent_action_for(turn, action: "resolve", resolution: { "reason" => "confirmado_pelo_cliente" }).except("reply")
    AgentActions::Apply.call(action)
    turn.ticket.reload
  end

  it "RN-08: duas mensagens reabrem uma vez, com seqs distintos e preservando a fila" do
    ticket = resolved_case
    version = ticket.assignment_version
    results = run_concurrently { |i| ingest("voltou a falhar #{i}") }
    expect(results).to all(be_a(Ingestion::Receive::Result))
    expect(results.map { _1.ticket.id }.uniq).to eq([ ticket.id ])
    expect(results.map { _1.message.seq }.uniq.size).to eq(2)
    expect(ticket.reload.assignment_version).to eq(version + 1)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.reopened").count).to eq(1)
  end

  it "RN-09: dois schedulers e dois workers fecham uma única vez" do
    ticket = resolved_case
    travel_to(ticket.close_due_at + 1.second) do
      ids = run_concurrently { Deadlines::TicketClose.call(now: Time.current, limit: 10) }.flatten
      expect(ids.size).to eq(1)
      expect(run_concurrently { TicketLifecycle::DeadlineAction.call(ids.sole) }.map(&:status))
        .to contain_exactly(:closed, :already_done)
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.closed").count).to eq(1)
    end
  end

  it "RN-47: duas resoluções do mesmo turno persistem um único resumo" do
    turn = opened_turn("deu certo")
    action = agent_action_for(turn, action: "resolve", resolution: { "reason" => "confirmado_pelo_cliente" }).except("reply")
    results = run_concurrently { AgentActions::Apply.call(action) }
    expect(results.map(&:status)).to contain_exactly(:applied, :duplicate)
    expect(TicketSummary.where(ticket_id: turn.ticket_id).count).to eq(1)
  end
end
