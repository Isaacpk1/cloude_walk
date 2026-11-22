require "rails_helper"

RSpec.describe Routing::Evaluate do
  let(:brand) { create(:brand, :infinitepay) }
  let(:team) { create(:team, brand:) }
  let(:supervisor) { create(:user, role: "supervisor") }
  let!(:geral) { create(:routing_queue, team:, is_default: true, name: "Geral") }
  let(:credito) { create(:routing_queue, team:, name: "Crédito", ai_first: false) }
  let(:credito_vip) { create(:routing_queue, team:, name: "Crédito VIP", ai_first: false) }
  let(:maquininha) { create(:routing_queue, team:, name: "Maquininha") }

  def attrs(**overrides)
    { "brand" => brand.slug, "channel" => "whatsapp", "category" => "outros", "priority" => "media", "tags" => [] }
      .merge(overrides.stringify_keys)
  end

  def publish(*rules, default_queue: geral, on: brand)
    RoutingRuleset.publish!(brand: on, rules: ruleset_json(*rules), default_queue:, created_by: supervisor)
  end

  def route(**overrides) = described_class.call(brand:, attributes: attrs(**overrides))

  describe "RF-15, RN-16: a primeira regra que casa decide" do
    it "devolve a fila, a versão da fila e do conjunto e a explicação da regra" do
      publish([ "Crédito alto", credito, [ [ %w[category eq credito], [ "priority", "in", %w[alta critica] ] ] ] ])

      decision = route(category: "credito", priority: "alta")

      expect(decision).to have_attributes(
        queue: credito, queue_version: 1, ruleset_version: 1, rule_index: 0, rule_name: "Crédito alto", group_index: 0,
        conditions: [ { "field" => "category", "op" => "eq", "value" => "credito" },
                      { "field" => "priority", "op" => "in", "value" => %w[alta critica] } ],
        default: false, skipped_rules: []
      )
      expect(decision.queue_name).to eq("Crédito")
    end

    it "exemplo da RN-16: a regra mais específica vem antes e vence, mesmo que a seguinte também case" do
      publish([ "Crédito VIP", credito_vip, [ [ %w[category eq credito], %w[tags contains vip] ] ] ],
              [ "Crédito", credito, [ [ %w[category eq credito] ] ] ])

      expect(route(category: "credito", tags: %w[vip])).to have_attributes(queue: credito_vip, rule_index: 0)
      expect(route(category: "credito", tags: [])).to have_attributes(queue: credito, rule_index: 1)
    end

    it "ordem: com as mesmas regras invertidas, a outra vence" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ],
              [ "Crédito VIP", credito_vip, [ [ %w[category eq credito], %w[tags contains vip] ] ] ])

      expect(route(category: "credito", tags: %w[vip])).to have_attributes(queue: credito, rule_name: "Crédito")
    end

    it "nenhuma regra casa: fila padrão do conjunto, com a versão do conjunto e sem regra" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])

      expect(route(category: "pix")).to have_attributes(
        queue: geral, queue_version: 1, ruleset_version: 1, rule_index: nil, rule_name: nil, group_index: nil,
        conditions: [], default: true, skipped_rules: []
      )
    end

    it "repetição: avaliar duas vezes os mesmos dados dá a mesma decisão" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])

      expect(route(category: "credito")).to eq(route(category: "credito"))
    end
  end

  describe "RF-14, ADR-003: E dentro do grupo, OU entre grupos" do
    before do
      publish([ "Maquininha ou urgente", maquininha, [ [ %w[category eq maquininha], %w[channel neq email] ],
                                                       [ %w[tags contains urgente] ] ] ])
    end

    it "casa pelo primeiro grupo só se todas as condições dele casarem" do
      expect(route(category: "maquininha", channel: "chat")).to have_attributes(queue: maquininha, group_index: 0)
      expect(route(category: "maquininha", channel: "email")).to have_attributes(default: true)
    end

    it "casa pelo segundo grupo quando o primeiro falha, e informa as condições do grupo que casou" do
      decision = route(category: "pix", channel: "email", tags: %w[urgente])

      expect(decision).to have_attributes(queue: maquininha, group_index: 1,
                                          conditions: [ { "field" => "tags", "op" => "contains", "value" => "urgente" } ])
    end
  end

  describe "RF-14: operadores" do
    {
      "eq" => [ %w[category eq pix], { category: "pix" }, { category: "credito" } ],
      "neq" => [ %w[channel neq email], { channel: "chat" }, { channel: "email" } ],
      "in" => [ [ "priority", "in", %w[alta critica] ], { priority: "critica" }, { priority: "media" } ],
      "not_in" => [ [ "priority", "not_in", %w[baixa media] ], { priority: "alta" }, { priority: "baixa" } ],
      "contains" => [ %w[tags contains vip], { tags: %w[novo vip] }, { tags: %w[novo] } ],
      "eq em brand" => [ %w[brand eq infinitepay], {}, nil ]
    }.each do |label, (condition, matching, other)|
      it "#{label}: casa e não casa" do
        publish([ "Regra", maquininha, [ [ condition ] ] ])

        expect(route(**matching)).to have_attributes(queue: maquininha, default: false)
        expect(route(**other)).to have_attributes(queue: geral, default: true) if other
      end
    end

    it "campo ausente nos atributos não casa eq nem in, casa neq" do
      publish([ "Sem categoria eq", credito, [ [ %w[category eq credito] ] ] ],
              [ "Sem categoria in", credito_vip, [ [ [ "category", "in", %w[credito] ] ] ] ],
              [ "Sem categoria neq", maquininha, [ [ %w[category neq credito] ] ] ])

      expect(route(category: nil)).to have_attributes(queue: maquininha, rule_index: 2)
      expect(described_class.call(brand:, attributes: { "channel" => "chat" })).to have_attributes(queue: maquininha)
    end

    it "tags nulas não quebram contains" do
      publish([ "VIP", credito_vip, [ [ %w[tags contains vip] ] ] ])

      expect(route(tags: nil)).to have_attributes(default: true)
    end
  end

  describe "RN-15: regra que aponta para fila inativa é pulada e registrada" do
    it "segue para a próxima regra que casa e registra a pulada" do
      publish([ "Crédito VIP", credito_vip, [ [ %w[category eq credito] ] ] ],
              [ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      credito_vip.update!(active: false)

      decision = route(category: "credito")

      expect(decision).to have_attributes(queue: credito, rule_index: 1)
      expect(decision.skipped_rules).to eq([ { "rule_index" => 0, "rule_name" => "Crédito VIP",
                                               "queue_id" => credito_vip.id, "reason" => "fila_inativa" } ])
    end

    it "regra que não casaria não entra em skipped_rules" do
      publish([ "Maquininha", maquininha, [ [ %w[category eq maquininha] ] ] ])
      maquininha.update!(active: false)

      expect(route(category: "pix")).to have_attributes(default: true, skipped_rules: [])
    end

    it "fila padrão do conjunto inativa: cai na fila is_default ativa da marca" do
      outra = create(:routing_queue, team:, name: "Outra padrão")
      publish(default_queue: outra)
      outra.update!(active: false)

      expect(route).to have_attributes(queue: geral, default: true, ruleset_version: 1)
    end
  end

  describe "sem conjunto de regras na marca" do
    it "cai na fila is_default ativa da marca, sem versão do conjunto" do
      expect(route).to have_attributes(queue: geral, queue_version: 1, ruleset_version: nil, rule_index: nil, default: true)
    end

    it "sem nenhuma fila ativa padrão, a decisão vem sem fila" do
      geral.update!(active: false)

      expect(route).to have_attributes(queue: nil, queue_version: nil, default: true)
    end
  end

  describe "RN-15, invariante 6: isolamento por marca" do
    let(:jim) { create(:brand, :jim) }
    let(:jim_team) { create(:team, brand: jim) }
    let!(:jim_geral) { create(:routing_queue, team: jim_team, is_default: true, name: "General") }
    let(:jim_credit) { create(:routing_queue, team: jim_team, name: "Credit") }

    it "usa o conjunto da própria marca, nunca o da outra" do
      publish([ "Credit", jim_credit, [ [ %w[category eq credito] ] ] ], default_queue: jim_geral, on: jim)

      expect(route(category: "credito")).to have_attributes(queue: geral, ruleset_version: nil)
      expect(described_class.call(brand: jim, attributes: attrs(brand: "jim", category: "credito")))
        .to have_attributes(queue: jim_credit, ruleset_version: 1)
    end

    it "o campo brand vem da marca do atendimento, não dos atributos informados" do
      publish([ "Só JIM", credito, [ [ %w[brand eq jim] ] ] ])

      expect(route(brand: "jim")).to have_attributes(default: true)
    end

    it "nunca devolve fila de outra marca, mesmo com o JSON da regra adulterado para apontar para ela" do
      ruleset = publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      forged = ruleset.rules.deep_dup.tap { _1["rules"][0]["queue_id"] = jim_credit.id }
      allow(RoutingRuleset).to receive(:find_by!).and_return(RoutingRuleset.new(ruleset.attributes.merge("rules" => forged)))
      Routing::Evaluate.cache.clear

      decision = route(category: "credito")

      expect(decision.queue).to eq(geral)
      expect(decision.skipped_rules).to eq([ { "rule_index" => 0, "rule_name" => "Crédito", "queue_id" => jim_credit.id,
                                               "reason" => "fila_fora_da_marca" } ])
    end
  end

  describe "RF-16, RN-18, RNF-07, ADR-013: versão nova vale no roteamento seguinte, sem reinício" do
    it "o cache confere o número da versão a cada roteamento" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      expect(route(category: "credito")).to have_attributes(queue: credito, ruleset_version: 1)

      publish([ "Crédito VIP", credito_vip, [ [ %w[category eq credito] ] ] ])

      expect(route(category: "credito")).to have_attributes(queue: credito_vip, ruleset_version: 2)
    end

    it "com a versão igual, não relê as regras do banco" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      route(category: "credito")
      allow(RoutingRuleset).to receive(:find_by!).and_call_original

      3.times { route(category: "credito") }

      expect(RoutingRuleset).not_to have_received(:find_by!)
    end

    it "fila desativada depois da publicação vale no roteamento seguinte, mesmo com o conjunto em cache" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      expect(route(category: "credito").queue).to eq(credito)

      credito.update!(active: false)

      expect(route(category: "credito")).to have_attributes(queue: geral, default: true)
    end

    it "a versão nova da fila aparece no roteamento seguinte" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])
      credito.publish_version!(name: "Crédito e empréstimos", ai_first: false, created_by: supervisor)

      expect(route(category: "credito")).to have_attributes(queue_version: 2, queue_name: "Crédito e empréstimos")
    end

    it "é só leitura: avaliar não grava nada" do
      publish([ "Crédito", credito, [ [ %w[category eq credito] ] ] ])

      expect { route(category: "credito") }.not_to change { [ AuditEvent.count, RoutingRuleset.count, QueueVersion.count ] }
    end
  end
end
