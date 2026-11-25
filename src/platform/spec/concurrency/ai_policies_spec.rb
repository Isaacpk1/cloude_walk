require "rails_helper"

RSpec.describe "ADR-028: publicações concorrentes dos tempos da IA", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:setup) { distribution_setup(brand) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }

  it "RN-20: duas publicações produzem versões inteiras e consecutivas" do
    results = run_concurrently do |i|
      Configuration::AiPolicies.publish(brand: Brand.find(brand.id), attributes: { turn_deadline: 10 + i }, created_by: boss)
    end
    expect(results.map(&:ok)).to eq([ true, true ])
    versions = AiPolicyVersion.where(brand_id: brand.id).order(:version)
    expect(versions.map(&:version)).to eq([ 1, 2 ])
    expect(versions.map { _1.settings["turn_deadline"] }).to match_array([ 10, 11 ])
  end
end
