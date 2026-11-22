# Blocos 08 e 09: prazo do aviso de progresso no ciclo (RN-57) e espelho da DLQ para o supervisor
# (RF-34, RF-37, RN-45, RN-48; 07, seção 4).
class AddProgressAndDeadLetters < ActiveRecord::Migration[8.1]
  def change
    # RN-57: um aviso de progresso por ciclo, aos 15 s desde first_pending_at.
    add_column :tickets, :progress_due_at, :datetime
    add_check_constraint :tickets, "progress_due_at IS NULL OR first_pending_at IS NOT NULL",
                         name: "tickets_progress_requires_cycle_check"
    add_index :tickets, :progress_due_at, where: "progress_due_at IS NOT NULL"
    add_index :tickets, :ai_deadline_at, where: "ai_deadline_at IS NOT NULL"

    # Uma linha por mensagem lida do tópico de DLQ. A marca e o atendimento ficam nulos quando o corpo
    # não permite correlacionar com segurança (ADR-014: sem correlação não há leitura de dados de negócio).
    create_table :dead_letters do |t|
      t.references :brand, foreign_key: true
      t.references :ticket, foreign_key: true
      t.string :topic, null: false
      t.integer :partition, null: false
      t.bigint :offset, null: false
      t.string :source, null: false        # broker, agent-mock, platform
      t.string :reason, null: false        # dlq_reason
      t.string :event_id
      t.string :trace_id
      t.integer :turn
      t.jsonb :violations, null: false, default: []
      t.jsonb :headers, null: false, default: {}
      t.text :payload, null: false         # corpo como chegou (pode não ser JSON)
      t.text :error
      t.integer :attempts, null: false, default: 0
      t.string :outcome                    # escalated, audited, uncorrelated (RN-45)
      t.datetime :reprocessed_at
      t.datetime :created_at, null: false
    end
    add_index :dead_letters, [ :topic, :partition, :offset ], unique: true
    add_index :dead_letters, :event_id
    add_index :dead_letters, :created_at
    add_check_constraint :dead_letters, "source IN ('broker', 'agent-mock', 'platform')", name: "dead_letters_source_check"
    add_check_constraint :dead_letters, "outcome IS NULL OR outcome IN ('escalated', 'audited', 'uncorrelated')",
                         name: "dead_letters_outcome_check"
    add_check_constraint :dead_letters, "ticket_id IS NULL OR brand_id IS NOT NULL", name: "dead_letters_ticket_brand_check"
    add_foreign_key :dead_letters, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_dead_letters_ticket_same_brand"
  end
end
