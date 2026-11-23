require "rails_helper"

RSpec.describe Distribution::ReturnToQueue, "RN-31, RN-23, RN-32: devolução do caso do analista offline" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let(:team) { setup[:team] }
  let(:queue) { setup[:queue] }
  let(:offline_since) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:started_at) { offline_since - 20.minutes }
  let(:due_at) { offline_since + 5.minutes }
  let(:analyst) { analyst_in(team, status: "offline").tap { _1.update_columns(status_changed_at: offline_since) } }
  let!(:ticket) { case_with(analyst, brand: infinitepay, queue:, identity: "acc_a", started_at:, sla_due_at: due_at) }
  let(:db_now) { offline_since + 10.minutes }

  before { allow(DatabaseClock).to receive(:now) { db_now } }

  def item_for(target = ticket)
    Deadlines::AnalystOffline.call(now: offline_since + 10.minutes, limit: 10, ticket_ids: [ target.id ])
    OutboxEvent.find_by!(ticket_id: target.id, event_type: "analyst.offline")
  end

  def work(item) = described_class.call(item.id)

  it "RN-31: devolve o caso à fila, tira o responsável, libera a vaga e conclui o item" do
    item = item_for

    result = work(item)

    expect(result).to have_attributes(status: :returned, reason: "analista_offline")
    expect(ticket.reload).to have_attributes(state: "aguardando_humano", assignee_id: nil, assignment_version: 2)
    expect(analyst.reload.active_count).to eq(0)
    expect(item.reload.completed_at).to be_present
  end

  it "RN-23, RN-31, RN-32: o SLA já consumido é preservado, sem reiniciar" do
    work(item_for)

    expect(ticket.reload).to have_attributes(sla_started_at: started_at, sla_due_at: due_at)
  end

  it "RF-54: audita ticket.returned_to_queue com o analista, desde quando estava offline e o prazo preservado" do
    item = item_for
    work(item)

    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.returned_to_queue").sole).to have_attributes(
      brand_id: infinitepay.id, trace_id: item.trace_id,
      data: a_hash_including("from_assignee_id" => analyst.id, "offline_since" => offline_since.utc.iso8601(3),
                             "sla_due_at" => due_at.utc.iso8601(3), "reason" => "analista_offline",
                             "state_from" => "com_analista", "assignment_version" => 2)
    )
  end

  it "o caso devolvido volta a ser distribuído a outro analista online" do
    work(item_for)
    outro = analyst_in(team)

    expect(Distribution::Run.call(now: db_now, limit: 10)).to eq([ ticket.id ])
    expect(ticket.reload.assignee_id).to eq(outro.id)
  end

  it "aguardando_cliente também volta para aguardando_humano" do
    waiting = case_with(analyst, brand: infinitepay, queue:, identity: "acc_b", state: "aguardando_cliente")

    work(item_for(waiting))

    expect(waiting.reload.state).to eq("aguardando_humano")
  end

  it "RN-31: se o analista voltou antes, o caso continua com ele e o item é descartado com auditoria" do
    item = item_for
    analyst.update_columns(status: "online", status_changed_at: offline_since + 8.minutes)

    expect(work(item)).to have_attributes(status: :discarded, reason: "analista_voltou")
    expect(ticket.reload).to have_attributes(state: "com_analista", assignee_id: analyst.id, assignment_version: 1)
    expect(analyst.reload.active_count).to eq(1)
    expect(item.reload.completed_at).to be_present
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.return_discarded").sole.data)
      .to include("reason" => "analista_voltou")
  end

  it "tempo: se pelo relógio do banco ainda não passaram 10 min, o item fica aberto para o prazo gravado" do
    item = item_for
    allow(DatabaseClock).to receive(:now) { offline_since + 9.minutes + 59.seconds }

    expect(work(item)).to have_attributes(status: :not_due)
    expect(item.reload.completed_at).to be_nil
    expect(ticket.reload.state).to eq("com_analista")
  end

  it "atribuição mudou: o caso já foi devolvido e redistribuído, então o item é descartado" do
    item = item_for
    ticket.update_columns(assignment_version: 4)

    expect(work(item)).to have_attributes(status: :discarded, reason: "atribuicao_mudou")
    expect(analyst.reload.active_count).to eq(1)
  end

  it "o caso mudou de estado (resolvido): descarta sem tocar nada" do
    item = item_for
    ticket.update_columns(state: "resolvido")

    expect(work(item)).to have_attributes(status: :discarded, reason: "fora_do_analista")
  end

  it "repetição: o worker duas vezes devolve uma vez só e libera uma vaga só" do
    item = item_for

    expect([ work(item).status, work(item).status ]).to eq(%i[returned already_done])
    expect(analyst.reload.active_count).to eq(0)
    expect(ticket.reload.assignment_version).to eq(2)
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "ticket.returned_to_queue").count).to eq(1)
  end

  it "a carga nunca fica abaixo de zero" do
    item = item_for
    analyst.update_columns(active_count: 0)

    work(item)

    expect(analyst.reload.active_count).to eq(0)
    expect(ticket.reload.state).to eq("aguardando_humano")
  end

  it "item inexistente é ignorado" do
    expect(described_class.call(0)).to have_attributes(status: :skipped)
  end

  it "RF-25 (marca errada): o banco recusa um item de uma marca apontando para o caso de outra" do
    item = item_for

    expect { ActiveRecord::Base.transaction(requires_new: true) { item.update_columns(brand_id: jim.id) } }.to raise_error(ActiveRecord::InvalidForeignKey, /fk_outbox_events_ticket_same_brand/)
    expect(work(item).status).to eq(:returned)
  end
end
