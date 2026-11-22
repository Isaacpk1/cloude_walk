require "rails_helper"

RSpec.describe RoutingRuleset do
  let(:brand) { create(:brand, :infinitepay) }
  let(:team) { create(:team, brand:) }
  let(:supervisor) { create(:user, role: "supervisor") }
  let(:geral) { create(:routing_queue, team:, is_default: true, name: "Geral") }
  let(:credito) { create(:routing_queue, team:, name: "Crédito", ai_first: false) }
  let(:rules) { ruleset_json([ "Crédito", credito, [ [ %w[category eq credito] ] ] ]) }

  # Cada violação do banco aborta a transação: um savepoint por tentativa mantém o teste usando a mesma conexão.
  def savepoint(&) = described_class.transaction(requires_new: true, &)

  def publish(rules: self.rules, default_queue: geral, brand: self.brand)
    described_class.publish!(brand:, rules:, default_queue:, created_by: supervisor)
  end

  describe "RN-20, ADR-013: o conjunto inteiro é versionado" do
    it "a primeira publicação é a versão 1, com regras, fila padrão e autor (RF-18)" do
      ruleset = publish

      expect(ruleset).to have_attributes(brand:, version: 1, rules:, default_queue: geral, created_by: supervisor)
      expect(ruleset.created_at).to be_present
      expect(described_class.current_for(brand)).to eq(ruleset)
    end

    it "publicar de novo cria a versão 2 e preserva a 1 como estava" do
      v1 = publish
      v2 = publish(rules: ruleset_json)

      expect(v2.version).to eq(2)
      expect(v1.reload.rules).to eq(rules)
      expect(described_class.current_for(brand)).to eq(v2)
    end

    it "aceita as chaves como símbolos e grava o JSON com chaves de texto" do
      ruleset = publish(rules: rules.deep_symbolize_keys)

      expect(ruleset.reload.rules).to eq(rules)
    end

    it "a versão publicada é só leitura no Ruby" do
      expect { publish.update!(rules: ruleset_json) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "o banco recusa UPDATE e DELETE, mesmo sem passar pelo modelo (gatilho)" do
      v1 = publish

      expect { savepoint { described_class.where(id: v1.id).update_all(version: 9) } }.to raise_error(ActiveRecord::StatementInvalid, /só inserção/)
      expect { savepoint { described_class.where(id: v1.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /só inserção/)
      expect(v1.reload.version).to eq(1)
    end

    it "o banco recusa versão repetida na marca e versão menor que 1" do
      publish
      row = { brand_id: brand.id, rules:, default_queue_id: geral.id, created_by_id: supervisor.id, created_at: Time.current }

      expect { savepoint { described_class.insert_all!([ row.merge(version: 1) ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { savepoint { described_class.insert_all!([ row.merge(version: 0) ]) } }.to raise_error(ActiveRecord::StatementInvalid, /version/)
    end

    it "as versões de cada marca são independentes" do
      jim_team = create(:team, brand: create(:brand, :jim))
      jim_default = create(:routing_queue, team: jim_team, is_default: true)
      publish
      publish

      expect(publish(brand: jim_team.brand, rules: ruleset_json, default_queue: jim_default).version).to eq(1)
    end
  end

  describe "ADR-003: o conjunto segue o esquema routing_rules v1" do
    it "recusa conjunto fora do esquema e não grava versão" do
      bad = rules.deep_dup.tap { _1["rules"][0]["any"][0]["all"][0]["op"] = "gt" }

      expect { publish(rules: bad) }.to raise_error(RoutingRuleset::InvalidRules) { |e|
        expect(e.violations).to include(a_string_matching(%r{/rules/0/any/0/all/0/op}))
      }
      expect(described_class.count).to eq(0)
    end
  end

  describe "RF-17, RN-15: regras só apontam para filas ativas da mesma marca" do
    it "exige a fila padrão" do
      expect { publish(default_queue: nil) }.to raise_error(RoutingRuleset::InvalidRules, /fila padrão/)
    end

    it "recusa fila padrão inativa" do
      geral.update!(active: false)

      expect { publish }.to raise_error(RoutingRuleset::InvalidRules, /fila padrão/)
    end

    it "recusa regra que aponta para fila inativa" do
      credito.update!(active: false)

      expect { publish }.to raise_error(RoutingRuleset::InvalidRules, /regra 1 «Crédito».*inativa/)
    end

    it "recusa regra que aponta para fila inexistente" do
      missing = ruleset_json([ "Fantasma", geral, [ [ %w[category eq pix] ] ] ]).tap { _1["rules"][0]["queue_id"] = 999_999_999 }

      expect { publish(rules: missing) }.to raise_error(RoutingRuleset::InvalidRules, /regra 1 «Fantasma».*não existe/)
    end

    context "marca errada" do
      let(:jim_team) { create(:team, brand: create(:brand, :jim)) }
      let(:jim_queue) { create(:routing_queue, team: jim_team, name: "JIM Credit") }

      it "recusa regra da InfinitePay que aponta para fila da JIM" do
        cross = ruleset_json([ "Crédito", jim_queue, [ [ %w[category eq credito] ] ] ])

        expect { publish(rules: cross) }.to raise_error(RoutingRuleset::InvalidRules, /não existe na marca/)
        expect(described_class.count).to eq(0)
      end

      it "recusa fila padrão de outra marca" do
        expect { publish(default_queue: jim_queue) }.to raise_error(RoutingRuleset::InvalidRules, /fila padrão/)
      end

      it "o banco recusa fila padrão ou regra de outra marca mesmo sem passar pelo modelo" do
        row = { brand_id: brand.id, version: 1, default_queue_id: geral.id, created_by_id: supervisor.id, created_at: Time.current }

        expect { savepoint { described_class.insert_all!([ row.merge(rules:, default_queue_id: jim_queue.id) ]) } }
          .to raise_error(ActiveRecord::InvalidForeignKey)
        expect { savepoint { described_class.insert_all!([ row.merge(rules: ruleset_json([ "x", jim_queue, [ [ %w[category eq pix] ] ] ])) ]) } }
          .to raise_error(ActiveRecord::StatementInvalid, /RN-15/)
      end
    end
  end
end
