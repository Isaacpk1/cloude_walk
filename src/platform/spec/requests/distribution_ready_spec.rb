require "rails_helper"

# Bloco 13, "pronto quando" (ROADMAP): dois workers disputam a última vaga e só um consegue ocupá-la, e um analista
# offline devolve o caso à fila preservando o SLA (RF-19, RF-25, RF-27, RF-45, RN-29 a RN-32). Tudo real: ingestão,
# triagem, SLA da entrada na fila, volta do scheduler (`Deadlines::Loop#tick`), OutboxJob e Availability::Set.
RSpec.describe "RF-19, RF-25, RF-27, RF-45: pronto quando do bloco 13" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { triage_setup(infinitepay, ai_first: false) }
  let(:t0) { Time.utc(2026, 11, 24, 13, 0, 0) }
  let!(:ana) { analyst_in(config[:team], capacity: 1) }
  let!(:bruno) { analyst_in(config[:team], status: "offline", capacity: 1) }

  around { |example| travel_to(t0) { example.run } }

  before do
    stub_broker
    stub_channels(*Array.new(6) { { status: 200, message_id: "chat_out_#{SecureRandom.hex(3)}" } })
    allow(DatabaseClock).to receive(:now) { Time.current }
  end

  def tick = perform_enqueued_jobs { Deadlines::Loop.new.tick }

  # Um cliente escreve e a triagem manda o caso para a fila humana (fila sem IA), com o SLA começando aí.
  def new_case(identity)
    ticket = ingest("preciso falar sobre meu repasse", brand: "infinitepay", identity:).ticket
    run_triage(ticket)
    ticket.reload
  end

  it "RN-30: dois casos disputam a última vaga e só o primeiro da ordem a ocupa" do
    first = new_case("acc_1")
    second = new_case("acc_2")
    expect([ first, second ]).to all(have_attributes(state: "aguardando_humano", assignee_id: nil))

    tick

    expect(first.reload).to have_attributes(state: "com_analista", assignee_id: ana.id)
    expect(second.reload).to have_attributes(state: "aguardando_humano", assignee_id: nil)
    expect(ana.reload.active_count).to eq(1)
    expect(AuditEvent.where(event_type: "ticket.assigned").where("data->>'to' = 'analista'").pluck(:ticket_id)).to eq([ first.id ])
  end

  it "RN-31, RN-23: o analista fica offline por 10 min, o caso volta à fila com o mesmo SLA e vai para outro analista" do
    first = new_case("acc_1")
    second = new_case("acc_2")
    started = first.sla_started_at
    due = first.sla_due_at
    tick
    expect(first.reload.assignee_id).to eq(ana.id)

    Availability::Set.call(user: ana, status: "offline")
    Availability::Set.call(user: bruno, status: "online")
    tick # Bruno entra: pega o caso que espera (second); Ana segue com o dela por 10 min
    expect(first.reload.assignee_id).to eq(ana.id)
    expect(second.reload.assignee_id).to eq(bruno.id)

    travel 9.minutes + 59.seconds
    tick
    expect(first.reload.assignee_id).to eq(ana.id)

    travel 1.second
    Availability::Set.call(user: bruno, status: "pausa") # sem vaga nem disponibilidade para o caso devolvido
    tick

    expect(first.reload).to have_attributes(state: "aguardando_humano", assignee_id: nil, assignment_version: 2,
                                            sla_started_at: started, sla_due_at: due)
    expect(ana.reload.active_count).to eq(0)
    expect(AuditEvent.where(ticket_id: first.id, event_type: "ticket.returned_to_queue").sole.data)
      .to include("reason" => "analista_offline", "sla_due_at" => due.utc.iso8601(3))

    Availability::Set.call(user: bruno, status: "online")
    bruno.update_columns(active_count: 0)
    tick

    expect(first.reload).to have_attributes(state: "com_analista", assignee_id: bruno.id, sla_due_at: due)
  end

  it "RN-31: se o analista volta antes dos 10 min, o caso continua com ele" do
    first = new_case("acc_1")
    tick
    Availability::Set.call(user: ana, status: "offline")

    travel 9.minutes
    Availability::Set.call(user: ana, status: "online")
    travel 5.minutes
    tick

    expect(first.reload).to have_attributes(state: "com_analista", assignee_id: ana.id, assignment_version: 1)
    expect(OutboxEvent.where(event_type: "analyst.offline")).to be_empty
  end

  it "RN-25, RN-26: o caso sem analista alerta aos 80% do prazo, sobe de prioridade e depois estoura" do
    ana.update_columns(status: "offline")
    ticket = new_case("acc_1")
    ticket.update_columns(priority: "baixa", sla_due_at: ticket.sla_started_at + 10.minutes)

    travel 8.minutes
    tick
    expect(ticket.reload).to have_attributes(priority: "media", sla_breached: false)
    expect(ticket.sla_alerted_at).to be_present

    travel 2.minutes
    tick
    expect(ticket.reload.sla_breached).to be(true)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: %w[ticket.priority_raised sla.breached]).pluck(:event_type))
      .to contain_exactly("ticket.priority_raised", "sla.breached")
  end
end
