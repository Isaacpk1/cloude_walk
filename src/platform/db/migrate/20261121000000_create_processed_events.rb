# Bloco 04: idempotência do consumer de retorno (07, seção 4; RN-47, RNF-15; invariante 3).
# A marcação de "processado" entra na mesma transação do efeito: se a transação cai, o evento volta
# do Kafka e é processado de novo; se ela confirma, a reentrega encontra a chave e não tem efeito.
class CreateProcessedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :processed_events, primary_key: [ :consumer, :event_id ] do |t|
      t.string :consumer, null: false
      t.uuid :event_id, null: false
      # Relógio do banco, no instante da gravação (como audit_events.occurred_at).
      t.datetime :processed_at, null: false, default: -> { "clock_timestamp()" }
    end

    # RN-56, invariante 8: um turno só fica `applied` com o event_id da ação aplicada, e só ele o tem.
    add_check_constraint :ai_turns, "(status = 'applied') = (applied_event_id IS NOT NULL)",
                         name: "ai_turns_applied_event_check"
  end
end
