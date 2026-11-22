require "rails_helper"

RSpec.describe "RN-20, ADR-013: publicações simultâneas do conjunto de regras da mesma marca", :concurrency do
  it "viram versões seguidas, sem buraco nem duplicata, e não atrasam a outra marca" do
    team = create(:team, brand: create(:brand, :infinitepay))
    geral = create(:routing_queue, team:, is_default: true, name: "Geral")
    pix = create(:routing_queue, team:, name: "Pix")
    jim_team = create(:team, brand: create(:brand, :jim))
    jim_geral = create(:routing_queue, team: jim_team, is_default: true, name: "General")
    author = create(:user, role: "supervisor")

    results = run_concurrently(threads: 8) do |i|
      rules = ruleset_json([ "Pix #{i}", pix, [ [ %w[category eq pix] ] ] ])
      RoutingRuleset.publish!(brand: team.brand, rules:, default_queue: geral, created_by: author)
    end
    jim = RoutingRuleset.publish!(brand: jim_team.brand, rules: ruleset_json, default_queue: jim_geral, created_by: author)

    expect(results).to all(be_a(RoutingRuleset))
    expect(RoutingRuleset.where(brand: team.brand).order(:version).pluck(:version)).to eq((1..8).to_a)
    expect(RoutingRuleset.where(brand: team.brand).map { _1.rules["rules"][0]["name"] }.uniq.size).to eq(8)
    expect(jim.version).to eq(1)
  end
end
