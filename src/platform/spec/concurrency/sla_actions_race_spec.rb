require "rails_helper"

RSpec.describe Sla::Action, "RN-25, RN-26: workers de SLA concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let(:started) { Time.zone.parse("2026-11-24 10:00:00") }

  before { allow(DatabaseClock).to receive(:now) { started + 10.minutes } }

  def waiting(**) = waiting_case(brand: infinitepay, queue: setup[:queue], identity: "acc_a", started_at: started, sla_due_at: started + 10.minutes, **)

  it "RN-25: dois workers no mesmo alerta sobem a prioridade uma vez só" do
    ticket = waiting(priority: "baixa")
    item = OutboxEvent.find(Deadlines::SlaAlert.call(now: started + 9.minutes, limit: 5).sole)

    results = run_concurrently(threads: 2) { Sla::Alert.call(item.id) }

    expect(results).to all(be_a(Data))
    expect(results.map(&:status)).to match_array(%i[already_done alerted])
    expect(ticket.reload.priority).to eq("media")
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.priority_raised").count).to eq(1)
  end

  it "RN-26: dois workers no mesmo estouro marcam uma vez só" do
    ticket = waiting
    item = OutboxEvent.find(Deadlines::SlaBreach.call(now: started + 10.minutes, limit: 5).sole)

    results = run_concurrently(threads: 2) { Sla::Breach.call(item.id) }

    expect(results.map(&:status)).to match_array(%i[already_done breached])
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "sla.breached").count).to eq(1)
  end

  it "o estouro e a atribuição ao mesmo tempo: a ordem dos locks decide, e o resultado é sempre coerente" do
    ana = analyst_in(setup[:team])
    ticket = waiting
    item = OutboxEvent.find(Deadlines::SlaBreach.call(now: started + 10.minutes, limit: 5).sole)

    results = run_concurrently(threads: 2) do |i|
      i.zero? ? Sla::Breach.call(item.id) : Distribution::Assign.call(ticket_id: ticket.id, brand_id: infinitepay.id)
    end

    expect(results).to all(be_a(Data))
    ticket.reload
    # Estourou na fila e depois foi atribuído, ou foi atribuído antes e o estouro foi descartado: nunca estourado sem
    # que o worker tenha agido, e a vaga do analista bate com o estado do caso.
    expect(ticket.state).to eq("com_analista")
    expect(ana.reload.active_count).to eq(1)
    expect(item.reload.completed_at).to be_present
    expect(ticket.sla_breached).to eq(results.first.status == :breached)
  end
end
