require "rails_helper"

RSpec.describe Triage::Policy do
  let(:policy) { described_class.for(build(:brand, :infinitepay)) }

  it "RN-28: categorias somente humanas configuráveis; o padrão é cadastro (RN-35: alterar cadastro é de humano)" do
    expect(policy.human_only_categories).to eq(%w[cadastro])
    expect(policy.human_only?("cadastro")).to be(true)
    expect(policy.human_only?("repasses")).to be(false)

    custom = policy.with(human_only_categories: %w[credito])
    expect(custom.human_only?("credito")).to be(true)
    expect(custom.human_only?("cadastro")).to be(false)
  end

  it "RN-12: quatro níveis, na ordem do impacto" do
    expect(described_class::PRIORITIES).to eq(%w[critica alta media baixa])
    expect(policy.highest(%w[baixa alta media])).to eq("alta")
  end

  it "RN-13: o que não casa fica em outros, média" do
    expect(policy).to have_attributes(fallback_category: "outros", fallback_priority: "media")
  end

  it "RN-11: toda categoria com palavras tem prioridade de base, nos dois idiomas" do
    policy.keywords.each_value do |by_category|
      expect(by_category.keys - policy.categories).to be_empty
    end
    expect(policy.categories - policy.base_priority.keys).to eq([])
  end
end
