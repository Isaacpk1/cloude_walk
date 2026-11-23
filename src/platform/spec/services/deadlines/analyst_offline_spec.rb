require "rails_helper"

RSpec.describe Deadlines::AnalystOffline, "RN-31: analista offline por 10 minutos" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let(:team) { setup[:team] }
  let(:queue) { setup[:queue] }
  let(:offline_since) { Time.zone.parse("2026-11-24 10:00:00") }
  let(:analyst) { analyst_in(team, status: "offline").tap { _1.update_columns(status_changed_at: offline_since) } }
  let!(:ticket) { case_with(analyst, brand: infinitepay, queue:, identity: "acc_a") }

  def register(at, **) = described_class.call(now: at, limit: 50, **)

  it "RN-31: no limite exato de 10 min registra; um instante antes, não" do
    expect(register(offline_since + 10.minutes - 1.second)).to eq([])
    ids = register(offline_since + 10.minutes)

    item = OutboxEvent.find(ids.sole)
    expect(item).to have_attributes(event_type: "analyst.offline", ticket_id: ticket.id, brand_id: infinitepay.id,
                                    dedup_key: "analyst.offline:#{ticket.id}:1")
    expect(item.payload).to include("assignee_id" => analyst.id, "assignment_version" => 1)
  end

  it "RF-54: audita o registro com o analista e desde quando está offline" do
    register(offline_since + 11.minutes)

    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "analyst.offline_scheduled").sole.data).to include(
      "assignee_id" => analyst.id, "offline_since" => offline_since.utc.iso8601(3)
    )
  end

  it "RN-31: pausa não devolve, só offline" do
    analyst.update_columns(status: "pausa")

    expect(register(offline_since + 1.hour)).to eq([])
  end

  it "RN-31: analista online não devolve" do
    analyst.update_columns(status: "online")

    expect(register(offline_since + 1.hour)).to eq([])
  end

  it "RN-31: devolve casos em com_analista e aguardando_cliente, e só esses" do
    waiting = case_with(analyst, brand: infinitepay, queue:, identity: "acc_b", state: "aguardando_cliente")
    resolved = case_with(analyst, brand: infinitepay, queue:, identity: "acc_c", state: "resolvido")

    ids = register(offline_since + 10.minutes)

    expect(OutboxEvent.where(id: ids).pluck(:ticket_id)).to match_array([ ticket.id, waiting.id ])
    expect(OutboxEvent.where(ticket_id: resolved.id, event_type: "analyst.offline")).to be_empty
  end

  it "repetição: registrar duas vezes gera um item só" do
    expect(register(offline_since + 10.minutes).size).to eq(1)
    expect(register(offline_since + 11.minutes)).to eq([])
    expect(OutboxEvent.where(event_type: "analyst.offline").count).to eq(1)
  end

  it "a atribuição nova (assignment_version diferente) gera chave nova" do
    register(offline_since + 10.minutes)
    ticket.update_columns(assignment_version: 3)

    expect(register(offline_since + 11.minutes).size).to eq(1)
    expect(OutboxEvent.pluck(:dedup_key)).to include("analyst.offline:#{ticket.id}:1", "analyst.offline:#{ticket.id}:3")
  end

  it "RF-25 (marca errada): com brand_id, só os casos daquela marca" do
    jim_setup = distribution_setup(jim)
    jim_analyst = analyst_in(jim_setup[:team], status: "offline").tap { _1.update_columns(status_changed_at: offline_since) }
    case_with(jim_analyst, brand: jim, queue: jim_setup[:queue], identity: "acc_j")

    ids = register(offline_since + 10.minutes, brand_id: infinitepay.id)

    expect(OutboxEvent.where(id: ids).pluck(:brand_id).uniq).to eq([ infinitepay.id ])
  end

  it "acorda o worker depois do commit, pelo id do item" do
    expect { register(offline_since + 10.minutes) }.to have_enqueued_job(OutboxJob).with(be_a(String))
  end

  it "respeita o limit" do
    case_with(analyst, brand: infinitepay, queue:, identity: "acc_b")

    expect(described_class.call(now: offline_since + 10.minutes, limit: 1).size).to eq(1)
  end
end
