# Bloco 03: turno enviado ao agente e estado da publicação do outbox (07, seções 3.1, 3.4 e 4).
# O turno nasce com o evento no outbox, na mesma transação (07, seção 3.1, passo 3). A janela de
# agrupamento, a versão do contexto e os prazos no atendimento entram nos blocos 06 e 08.
class CreateAiTurnsAndPublication < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_turns do |t|
      # ADR-014: brand_id em toda tabela de negócio, com FK composta para a marca do atendimento.
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, null: false, foreign_key: true
      t.integer :turn, null: false
      t.integer :context_until_seq, null: false
      t.integer :assignment_version, null: false
      t.jsonb :context, null: false
      t.uuid :event_id, null: false
      t.string :status, null: false, default: "eligible"
      # Cópia do prazo do ciclo no envio (RN-46). A fonte passa a ser tickets.ai_deadline_at no bloco 08.
      t.datetime :deadline_at, null: false
      t.uuid :applied_event_id
      t.jsonb :response
      t.datetime :response_received_at
      t.timestamps
    end
    # RN-56: uma linha por turno; a resposta é correlacionada pelo event_id (invariante 4).
    add_index :ai_turns, [ :ticket_id, :turn ], unique: true
    add_index :ai_turns, :event_id, unique: true
    add_check_constraint :ai_turns, "status IN ('eligible', 'applied', 'superseded', 'expired')", name: "ai_turns_status_check"
    add_check_constraint :ai_turns, "turn >= 1", name: "ai_turns_turn_check"
    add_check_constraint :ai_turns, "context_until_seq >= 1", name: "ai_turns_context_until_seq_check"
    add_foreign_key :ai_turns, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_ai_turns_ticket_same_brand"

    # RN-43: retentativas contadas no item; o motivo da última falha fica à vista na recuperação.
    # O histórico de cada tentativa vai para a auditoria (RF-54).
    add_column :outbox_events, :attempts, :integer, null: false, default: 0
    add_column :outbox_events, :last_error, :text
    add_check_constraint :outbox_events, "attempts >= 0", name: "outbox_events_attempts_check"
  end
end
