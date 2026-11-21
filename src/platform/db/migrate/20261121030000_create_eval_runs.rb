# Bloco 07: resultado de cada execução de um eval (07, seção 4; ADR-023; RNF-30).
class CreateEvalRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :eval_runs, id: :uuid do |t|
      t.string :scenario, null: false
      t.string :status, null: false
      t.string :agent_model, null: false
      t.string :agent_version, null: false
      t.string :config_hash
      t.jsonb :expected, null: false, default: {}
      t.jsonb :observed, null: false, default: {}
      t.jsonb :checks, null: false, default: []
      # Evidência: o atendimento sintético e o trace da primeira mensagem (ADR-014: com a marca).
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, foreign_key: true
      t.string :trace_id
      t.text :error
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :eval_runs, [ :scenario, :started_at ]
    add_check_constraint :eval_runs, "status IN ('passed', 'failed', 'error')", name: "eval_runs_status_check"
    add_check_constraint :eval_runs, "jsonb_typeof(checks) = 'array'", name: "eval_runs_checks_check"
    add_foreign_key :eval_runs, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_eval_runs_ticket_same_brand"
    # Só inserção (como audit_events): uma execução nova é uma linha nova.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION eval_runs_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'eval_runs é só de inserção';
          END $$;
          CREATE TRIGGER eval_runs_no_update BEFORE UPDATE OR DELETE ON eval_runs
            FOR EACH ROW EXECUTE FUNCTION eval_runs_immutable();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER eval_runs_no_update ON eval_runs; DROP FUNCTION eval_runs_immutable();"
      end
    end
  end
end
