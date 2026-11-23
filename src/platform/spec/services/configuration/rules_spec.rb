require "rails_helper"

# Bloco 12 (RF-14, RF-15, RF-16, RF-17, RF-18, RNF-07): regras de roteamento publicadas pelo supervisor a partir do
# formulário (condições E, grupos OU), com validação em texto e versão nova a cada publicação.
RSpec.describe Configuration::Rules, "RF-14, RF-17: regras pelo formulário" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }
  let!(:credit) { Configuration::Queues.create(brand: infinitepay, team_id: setup[:team].id, name: "Crédito", created_by: boss).record }

  def form(rules, default: setup[:queue].id)
    described_class.publish(brand: infinitepay, rules:, default_queue_id: default, created_by: boss)
  end

  def credit_rule(extra = {})
    { "name" => "Crédito alto ou VIP", "queue_id" => credit.id.to_s,
      "groups" => [ { "conditions" => [ { "field" => "category", "op" => "eq", "value" => "credito" },
                                        { "field" => "priority", "op" => "in", "value" => "alta, critica" } ] },
                    { "conditions" => [ { "field" => "tags", "op" => "contains", "value" => "vip" } ] } ] }.merge(extra)
  end

  it "converte o formulário no formato do ADR-003 (E dentro do grupo, OU entre grupos) e publica a versão" do
    result = form([ credit_rule ])

    expect(result.ok).to be(true)
    ruleset = result.record
    expect(ruleset).to have_attributes(version: 1, default_queue_id: setup[:queue].id, created_by_id: boss.id)
    expect(ruleset.rules).to eq(
      "schema_version" => 1,
      "rules" => [ { "name" => "Crédito alto ou VIP", "queue_id" => credit.id,
                     "any" => [ { "all" => [ { "field" => "category", "op" => "eq", "value" => "credito" },
                                             { "field" => "priority", "op" => "in", "value" => %w[alta critica] } ] },
                                { "all" => [ { "field" => "tags", "op" => "contains", "value" => "vip" } ] } ] } ]
    )
  end

  it "RF-16, RNF-07: o avaliador usa a regra nova no atendimento seguinte, sem reinício" do
    attrs = { "channel" => "chat", "category" => "credito", "priority" => "alta", "tags" => [] }
    expect(Routing::Evaluate.call(brand: infinitepay, attributes: attrs).queue).to be_nil.or eq(setup[:queue])

    form([ credit_rule ])

    decision = Routing::Evaluate.call(brand: infinitepay, attributes: attrs)
    expect(decision.queue).to eq(credit)
    expect(decision.ruleset_version).to eq(1)
  end

  it "RF-18: cada publicação é uma versão nova; a antiga continua como estava" do
    form([ credit_rule ])
    form([])

    expect(RoutingRuleset.where(brand_id: infinitepay.id).order(:version).map { [ _1.version, _1.rules["rules"].size ] }).to eq([ [ 1, 1 ], [ 2, 0 ] ])
  end

  it "mostra cada problema em texto: fila inexistente, inativa, categoria desconhecida, condição vazia, nome em branco" do
    Configuration::Queues.set_active(brand: infinitepay, queue_id: credit.id, active: false, created_by: boss)

    expect(form([ credit_rule ]).errors).to include(a_string_matching(/inativa/))
    expect(form([ credit_rule("queue_id" => "999999") ]).errors).to include(a_string_matching(/não existe/))
    expect(form([ credit_rule("name" => " ") ]).errors).to include("regra 1: o nome é obrigatório")
    bad_category = credit_rule("groups" => [ { "conditions" => [ { "field" => "category", "op" => "eq", "value" => "astrologia" } ] } ])
    expect(form([ bad_category ]).errors).to include(a_string_matching(/categoria desconhecida/))
    empty_group = credit_rule("groups" => [ { "conditions" => [] } ])
    expect(form([ empty_group ]).errors).to include(a_string_matching(/condição/))
  end

  it "RF-17: sem fila padrão, ou com fila padrão de outra marca, é recusado" do
    other = distribution_setup(jim)[:queue]

    expect(form([], default: nil).errors).to include(a_string_matching(/fila padrão/))
    expect(form([], default: other.id).errors).to include(a_string_matching(/fila padrão/))
    expect(RoutingRuleset.where(brand_id: infinitepay.id)).to be_empty
  end

  it "ignora linhas totalmente vazias do formulário" do
    blank = { "name" => "", "queue_id" => "", "groups" => [ { "conditions" => [ { "field" => "", "op" => "", "value" => "" } ] } ] }

    expect(form([ blank ]).ok).to be(true)
    expect(RoutingRuleset.current_for(infinitepay).rules["rules"]).to eq([])
  end

  it "RN-20: duas publicações ao mesmo tempo viram versões seguidas", :concurrency do
    results = run_concurrently(threads: 2) { form([ credit_rule ]) }

    expect(results.map(&:ok)).to eq([ true, true ])
    expect(RoutingRuleset.where(brand_id: infinitepay.id).pluck(:version).sort).to eq([ 1, 2 ])
  end
end
