require "rails_helper"

# Stub do S3 (bloco 07): na integração vale o Evals::Catalog do executor (S2), com a mesma assinatura.
RSpec.describe "ADR-023, RNF-30: catálogo de cenários de eval" do
  it "lista a corrida-3s com nome, título e descrição" do
    scenario = Evals::Catalog.scenarios.find { _1[:name] == "corrida-3s" }

    expect(scenario).to include(:title, :description)
    expect(scenario[:title]).to be_present
    expect(Evals::Catalog.scenarios.map { _1[:name] }).to eq(Evals::Catalog.scenarios.map { _1[:name] }.uniq)
  end
end
