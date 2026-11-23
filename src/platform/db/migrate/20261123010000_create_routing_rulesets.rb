# Bloco 11: conjunto de regras de roteamento da marca, versionado inteiro (ADR-013), no formato do ADR-003.
# Regras críticas no banco (invariante 8): versão única e positiva por marca (RN-20), fila padrão obrigatória e da
# mesma marca (RF-17, RN-15), toda queue_id das regras numa fila ativa da mesma marca (RN-15) e só inserção (RN-20).
class CreateRoutingRulesets < ActiveRecord::Migration[8.1]
  def change
    # Alvo da FK composta: a fila padrão é da marca do conjunto.
    add_index :queues, %i[id brand_id], unique: true

    create_table :routing_rulesets do |t|
      t.references :brand, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.jsonb :rules, null: false
      t.bigint :default_queue_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    # Versão atual = maior versão da marca: o mesmo índice responde à consulta do cache (ADR-013).
    add_index :routing_rulesets, %i[brand_id version], unique: true
    add_check_constraint :routing_rulesets, "version >= 1", name: "routing_rulesets_version_check"
    add_check_constraint :routing_rulesets, "jsonb_typeof(rules -> 'rules') = 'array'", name: "routing_rulesets_rules_check"
    add_foreign_key :routing_rulesets, :queues, column: %i[default_queue_id brand_id], primary_key: %i[id brand_id],
                                                name: "fk_routing_rulesets_default_queue_same_brand"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION routing_rulesets_immutable() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'routing_rulesets é só inserção (RN-20): publique uma versão nova';
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER routing_rulesets_immutable
            BEFORE UPDATE OR DELETE ON routing_rulesets
            FOR EACH ROW EXECUTE FUNCTION routing_rulesets_immutable();

          -- RN-15: uma regra da InfinitePay não manda casos para uma fila da JIM, nem para fila inativa ou
          -- inexistente, mesmo numa gravação que não passe pelo modelo. Depois de publicada, a fila pode ser
          -- desativada: o roteamento pula a regra (Routing::Evaluate).
          CREATE FUNCTION routing_rulesets_queues_of_brand() RETURNS trigger AS $$
          DECLARE
            bad text;
          BEGIN
            SELECT rule ->> 'queue_id' INTO bad
              FROM jsonb_array_elements(NEW.rules -> 'rules') AS rule
             WHERE NOT EXISTS (
                     SELECT 1 FROM queues q
                      WHERE q.id::text = rule ->> 'queue_id' AND q.brand_id = NEW.brand_id AND q.active)
             LIMIT 1;
            IF FOUND THEN
              RAISE EXCEPTION 'regra aponta para fila % que não é ativa da marca % (RN-15)', bad, NEW.brand_id;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM queues q WHERE q.id = NEW.default_queue_id AND q.active) THEN
              RAISE EXCEPTION 'fila padrão % inativa (RF-17)', NEW.default_queue_id;
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER routing_rulesets_queues_of_brand
            BEFORE INSERT ON routing_rulesets
            FOR EACH ROW EXECUTE FUNCTION routing_rulesets_queues_of_brand();
        SQL
      end
      dir.down do
        execute <<~SQL
          DROP TRIGGER routing_rulesets_queues_of_brand ON routing_rulesets;
          DROP FUNCTION routing_rulesets_queues_of_brand();
          DROP TRIGGER routing_rulesets_immutable ON routing_rulesets;
          DROP FUNCTION routing_rulesets_immutable();
        SQL
      end
    end
  end
end
