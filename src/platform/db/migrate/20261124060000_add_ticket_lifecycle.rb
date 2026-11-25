class AddTicketLifecycle < ActiveRecord::Migration[8.0]
  def change
    change_table :tickets do |t|
      t.datetime :resolved_at
      t.string :resolution_source
      t.string :resolution_reason
      t.datetime :close_due_at
      t.datetime :waiting_since
      t.datetime :reminder_due_at
      t.datetime :inactivity_due_at
    end
    add_index :tickets, :close_due_at, where: "state = 'resolvido'", name: "tickets_due_close"
    add_index :tickets, :inactivity_due_at, where: "state = 'aguardando_cliente'", name: "tickets_due_inactivity"
    add_check_constraint :tickets, "(resolved_at IS NULL) = (close_due_at IS NULL)", name: "tickets_resolution_deadline_pair"
    add_check_constraint :tickets, "close_due_at IS NULL OR close_due_at >= resolved_at", name: "tickets_close_after_resolution"
    add_check_constraint :tickets, "resolution_source IS NULL OR resolution_source IN ('agent', 'human', 'inactivity')",
                         name: "tickets_resolution_source"
    add_check_constraint :tickets, "(waiting_since IS NULL) = (reminder_due_at IS NULL) AND " \
                                  "(waiting_since IS NULL) = (inactivity_due_at IS NULL)", name: "tickets_waiting_deadlines_pair"
    add_check_constraint :tickets, "waiting_since IS NULL OR " \
                                  "(reminder_due_at >= waiting_since AND inactivity_due_at > reminder_due_at)",
                         name: "tickets_waiting_deadlines_order"
    create_table :ticket_summaries do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, null: false
      t.integer :assignment_version, null: false
      t.datetime :resolved_at, null: false
      t.text :body, null: false
      t.datetime :created_at, null: false
    end
    add_index :ticket_summaries, %i[ticket_id assignment_version], unique: true
    add_foreign_key :ticket_summaries, :tickets, column: %i[ticket_id brand_id], primary_key: %i[id brand_id]
    add_check_constraint :ticket_summaries, "length(body) > 0", name: "ticket_summary_not_empty"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION ticket_summaries_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'resumo de resolução é imutável (ADR-027)';
          END $$;
          CREATE TRIGGER ticket_summaries_immutable BEFORE UPDATE OR DELETE ON ticket_summaries
            FOR EACH ROW EXECUTE FUNCTION ticket_summaries_immutable();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER ticket_summaries_immutable ON ticket_summaries; DROP FUNCTION ticket_summaries_immutable();"
      end
    end
  end
end
