# Bloco 05: entrega das saídas ao canal de origem (07, seções 3.1 passo 7, 3.2 e 4; RF-06, RNF-15).
# Uma linha por mensagem de saída. O delivery_id é estável em todas as tentativas e é a chave de
# idempotência no provedor. A ordem de entrega segue o seq da mensagem no atendimento (07, seção 3.2).
class CreateDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :deliveries do |t|
      # ADR-014: brand_id em toda tabela de negócio, com FK composta para a marca do atendimento.
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true, index: { unique: true }
      t.uuid :delivery_id, null: false, default: -> { "gen_random_uuid()" }
      t.integer :seq, null: false
      t.string :channel, null: false
      t.string :provider_account, null: false
      # reply e resolution (IA, bloco 05); progress (bloco 08), handoff_notice e analyst (bloco 10).
      t.string :kind, null: false
      t.integer :ai_assignment_version
      t.integer :ai_first_pending_seq
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :lease_until
      t.string :provider_message_id
      t.text :last_error
      t.string :trace_id, null: false
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :deliveries, :delivery_id, unique: true
    add_index :deliveries, [ :ticket_id, :seq ], unique: true
    add_index :deliveries, [ :brand_id, :channel, :provider_account, :provider_message_id ], unique: true,
              where: "provider_message_id IS NOT NULL", name: "index_deliveries_on_provider_message"
    # Busca da próxima saída aberta do atendimento (07, seção 3.2).
    add_index :deliveries, [ :ticket_id, :seq ], where: "status IN ('pending', 'sending')", name: "index_deliveries_open"

    add_check_constraint :deliveries, "status IN ('pending', 'sending', 'delivered', 'cancelled', 'failed')",
                         name: "deliveries_status_check"
    add_check_constraint :deliveries, "kind IN ('reply', 'resolution', 'progress', 'handoff_notice', 'analyst')",
                         name: "deliveries_kind_check"
    add_check_constraint :deliveries, "channel IN ('chat', 'whatsapp', 'email')", name: "deliveries_channel_check"
    add_check_constraint :deliveries, "attempts >= 0", name: "deliveries_attempts_check"
    add_check_constraint :deliveries, "seq >= 1", name: "deliveries_seq_check"
    # Entregue sempre tem a confirmação do provedor guardada (ROADMAP 05: "guardar a confirmação").
    add_check_constraint :deliveries, "(status = 'delivered') = (delivered_at IS NOT NULL)",
                         name: "deliveries_delivered_at_check"
    add_check_constraint :deliveries, "status <> 'delivered' OR provider_message_id IS NOT NULL",
                         name: "deliveries_delivered_confirmation_check"
    add_foreign_key :deliveries, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_deliveries_ticket_same_brand"
  end
end
