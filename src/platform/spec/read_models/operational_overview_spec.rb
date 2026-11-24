require "rails_helper"

RSpec.describe "RF-60, RNF-24: indicadores operacionais sem corte da listagem" do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:other) { create(:brand, :jim) }
  let!(:queue) { create(:routing_queue, team: create(:team, brand:), name: "Repasses") }
  let(:now) { Time.utc(2026, 11, 23, 15) }

  def ticket(brand: self.brand, queue: self.queue, **attrs)
    Ticket.create!(brand:, queue:, customer: create(:customer, brand:), channel: "chat", state: "com_ia", **attrs)
  end

  def overview(ids = [ brand.id ]) = OperationalOverview.new(brand_ids: ids, now:)

  it "RF-60: conta mais de 200 casos, separa fila sem nome, resolvidos e fechados e não mistura marcas" do
    201.times { ticket }
    ticket(queue: nil)
    ticket(state: "resolvido")
    ticket(state: "fechado")
    ticket(brand: other, queue: nil)

    rows = overview.rows
    expect(rows.find { _1.queue_id == queue.id }).to have_attributes(open_count: 201, brand_name: "InfinitePay", queue_name: "Repasses")
    expect(rows.find { _1.queue_id.nil? }.open_count).to eq(1)
    expect(rows.map(&:brand_id).uniq).to eq([ brand.id ])
    expect(overview([]).rows).to be_empty
  end

  it "RN-26, RF-60: mede espera só de quem aguarda e inclui SLA no prazo exato e marca permanente" do
    ticket(state: "aguardando_humano", sla_started_at: now - 100.seconds, sla_due_at: now)
    ticket(state: "aguardando_humano", sla_started_at: now - 20.seconds, sla_due_at: now + 1.second)
    ticket(state: "aguardando_humano")
    ticket(state: "com_analista", sla_started_at: now - 1.hour, sla_due_at: now - 1.second)
    ticket(state: "com_analista", sla_breached: true)

    expect(overview.rows.sole).to have_attributes(open_count: 5, waiting_count: 3, waiting_without_start: 1,
                                               average_wait_s: 60.0, max_wait_s: 100.0, outside_sla_count: 2)
  end

  it "RF-60: taxa por caso distinto na coorte de 24 h, inclusive os resolvidos e o limite exato" do
    start = now - 24.hours
    eligible = ticket(created_at: start, state: "resolvido")
    ticket(created_at: now)
    old = ticket(created_at: start - 0.001.seconds)
    2.times do
      [ eligible, old ].each do |record|
        AuditEvent.create!(brand:, ticket: record, event_type: "ticket.escalated", actor_type: "system",
                           trace_id: "a" * 32, data: {})
      end
    end

    expect(overview.rows.sole).to have_attributes(cohort_count: 2, escalated_count: 1, escalation_rate: 50.0)
    expect(overview.window_start).to eq(start)
  end

  it "RF-60: sem coorte não inventa taxa zero e sem espera não inventa duração" do
    ticket(created_at: now - 2.days)

    expect(overview.rows.sole).to have_attributes(cohort_count: 0, escalation_rate: nil, average_wait_s: nil, max_wait_s: nil)
  end
end
