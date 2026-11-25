require "rails_helper"

RSpec.describe "ADR-020, ADR-028: tempos da IA versionados por marca" do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:setup) { distribution_setup(brand) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }

  def publish(**attributes) = Configuration::AiPolicies.publish(brand:, attributes:, created_by: boss)

  it "ADR-020: publica sem mudar outra marca nem editar a versão anterior" do
    expect(publish(turn_deadline: 10, cycle_deadline: 30, progress_notice: 5).ok).to be(true)
    expect(publish(turn_deadline: 15).ok).to be(true)
    expect(Turns::Policy.for(brand).turn_deadline).to eq(15.seconds)
    expect(Turns::Policy.for(jim).turn_deadline).to eq(20.seconds)
    expect(AiPolicyVersion.where(brand_id: brand.id).order(:version).map(&:version)).to eq([ 1, 2 ])
    expect(AiPolicyVersion.where(brand_id: brand.id, version: 1).sole.settings["turn_deadline"]).to eq(10)
  end

  it "ADR-020: recusa limites inválidos sem publicar" do
    [ { turn_deadline: 4 }, { turn_deadline: 61 }, { cycle_deadline: 301 }, { cycle_deadline: 10 },
     { progress_notice: 60 }, { chat_window: -1 }, { chat_window: 5 }, { ceiling: 1 },
     { turn_deadline: "NaN" } ].each do |attributes|
      expect(publish(**attributes).ok).to be(false)
    end
    expect(AiPolicyVersion.count).to eq(0)
  end

  it "ADR-028: versão nova não altera ciclo que começou com os padrões" do
    first = ingest("oi")
    publish(turn_deadline: 10, cycle_deadline: 30, progress_notice: 5)
    ingest("meu repasse não caiu")
    turn = open_turn_for(first)
    expect(turn.deadline_at - turn.created_at).to be_within(1).of(20.seconds)
    expect(first.ticket.reload.ai_policy_snapshot.fetch("turn_deadline")).to eq(20)
    next_case = ingest("outro", identity: "acc_novo")
    expect(next_case.ticket.ai_deadline_at - next_case.ticket.first_pending_at).to eq(30.seconds)
    expect(next_case.ticket.ai_policy_snapshot.fetch("version")).to eq(1)
  end

  it "RNF-24: supervisor sem vínculo não publica na marca" do
    expect(Configuration::AiPolicies.publish(brand: jim, attributes: { turn_deadline: 10 }, created_by: boss).ok).to be(false)
  end
end
