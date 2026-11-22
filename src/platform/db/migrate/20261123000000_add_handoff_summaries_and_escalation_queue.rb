# Bloco 10 (07, seção 3.2): resumo do handoff (RN-39, RN-40), fila de escalas da marca (RF-42) e contador de trocas
# da IA (RN-33, item 6). Regras críticas no banco (invariante 8).
class AddHandoffSummariesAndEscalationQueue < ActiveRecord::Migration[8.1]
  def change
    # Um resumo por handoff: o atendimento e a atribuição que foi encerrada. Só inserção (RN-54): um resumo
    # tardio não substitui o primeiro; o estado do resumo é a linha.
    create_table :handoff_summaries do |t|
      t.references :brand, null: false, foreign_key: true
      t.bigint :ticket_id, null: false
      t.integer :from_assignment_version, null: false
      t.string :source, null: false
      t.string :status, null: false
      t.jsonb :fields
      t.string :missing_reason
      t.string :trace_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :handoff_summaries, %i[ticket_id from_assignment_version], unique: true
    add_foreign_key :handoff_summaries, :tickets, column: %i[ticket_id brand_id], primary_key: %i[id brand_id],
                                                  name: "fk_handoff_summaries_ticket_same_brand"
    add_check_constraint :handoff_summaries, "source IN ('agent', 'platform')", name: "handoff_summaries_source_check"
    add_check_constraint :handoff_summaries, "status IN ('available', 'missing')", name: "handoff_summaries_status_check"
    add_check_constraint :handoff_summaries,
                         "(status = 'available' AND fields IS NOT NULL) OR (status = 'missing' AND missing_reason IS NOT NULL)",
                         name: "handoff_summaries_status_fields_check"
    # RN-54, invariante 8: só inserção também no banco, como audit_events. TRUNCATE (limpeza dos testes) não passa por aqui.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION handoff_summaries_immutable() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'handoff_summaries é só inserção (RN-39, RN-54): o primeiro resumo do handoff vale';
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER handoff_summaries_immutable
            BEFORE UPDATE OR DELETE ON handoff_summaries
            FOR EACH ROW EXECUTE FUNCTION handoff_summaries_immutable();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER handoff_summaries_immutable ON handoff_summaries; DROP FUNCTION handoff_summaries_immutable();"
      end
    end

    # RF-42: a fila humana para onde o handoff vai até o roteamento por regras (bloco 11).
    add_column :queues, :escalation, :boolean, null: false, default: false
    add_index :queues, :brand_id, unique: true, where: "escalation AND active", name: "index_queues_one_escalation_per_brand"

    # RN-33, item 6: trocas da IA na atribuição atual (07, seção 4).
    add_column :tickets, :ai_turns_count, :integer, null: false, default: 0
    add_check_constraint :tickets, "ai_turns_count >= 0", name: "tickets_ai_turns_count_check"
  end
end
