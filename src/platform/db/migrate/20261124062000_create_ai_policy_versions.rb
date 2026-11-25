class CreateAiPolicyVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :tickets, :ai_policy_snapshot, :jsonb, null: false, default: {}
    add_check_constraint :tickets, "jsonb_typeof(ai_policy_snapshot) = 'object'", name: "tickets_ai_policy_object"
    create_table :ai_policy_versions do |t|
      t.references :brand, null: false, foreign_key: true
      t.integer :version, null: false
      t.jsonb :settings, null: false
      t.references :created_by, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    add_index :ai_policy_versions, %i[brand_id version], unique: true
    add_check_constraint :ai_policy_versions, "version > 0", name: "ai_policy_positive_version"
    add_check_constraint :ai_policy_versions, <<~SQL.squish, name: "ai_policy_limits"
      settings ?& ARRAY['turn_deadline','cycle_deadline','progress_notice','chat_window','whatsapp_window','email_window','ceiling']
      AND (settings->>'turn_deadline')::numeric BETWEEN 5 AND 60
      AND (settings->>'cycle_deadline')::numeric BETWEEN (settings->>'turn_deadline')::numeric AND 300
      AND (settings->>'progress_notice')::numeric > 0
      AND (settings->>'progress_notice')::numeric < (settings->>'cycle_deadline')::numeric
      AND (settings->>'ceiling')::numeric BETWEEN 0 AND 4
      AND (settings->>'chat_window')::numeric BETWEEN 0 AND (settings->>'ceiling')::numeric
      AND (settings->>'whatsapp_window')::numeric BETWEEN 0 AND (settings->>'ceiling')::numeric
      AND (settings->>'email_window')::numeric BETWEEN 0 AND (settings->>'ceiling')::numeric
    SQL
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION ai_policy_versions_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'versão dos tempos da IA é imutável (ADR-028)';
          END $$;
          CREATE TRIGGER ai_policy_versions_immutable BEFORE UPDATE OR DELETE ON ai_policy_versions
            FOR EACH ROW EXECUTE FUNCTION ai_policy_versions_immutable();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER ai_policy_versions_immutable ON ai_policy_versions; DROP FUNCTION ai_policy_versions_immutable();"
      end
    end
  end
end
