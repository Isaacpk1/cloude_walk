# Tabelas da ingestão do bloco 02 (07, seção 4): atendimento, mensagem, auditoria e outbox.
# Prazos de turno, SLA, ai_turns e deliveries entram nos blocos que os usam (06, 08, 05).
class CreateIngestionTables < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.string :channel, null: false
      t.string :state, null: false, default: "novo"
      # RF-10: preenchidos pela triagem e pelo roteamento (bloco 11).
      t.string :category
      t.string :priority
      t.references :queue, foreign_key: true
      t.integer :queue_version
      t.integer :ruleset_version
      t.references :assignee, foreign_key: { to_table: :users }
      t.string :tags, array: true, null: false, default: []
      t.references :linked_ticket, foreign_key: { to_table: :tickets }
      # 07, seção 3.4: atualizado na transação da ingestão, com a linha travada.
      t.integer :latest_customer_seq, null: false, default: 0
      t.integer :assignment_version, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :tickets, <<~SQL.squish, name: "tickets_state_check"
      state IN ('novo', 'em_triagem', 'com_ia', 'aguardando_humano', 'com_analista', 'aguardando_cliente',
                'resolvido', 'fechado')
    SQL
    add_check_constraint :tickets, "channel IN ('chat', 'whatsapp', 'email')", name: "tickets_channel_check"
    # RN-03: no máximo um atendimento aberto por cliente e canal, mesmo com webhooks simultâneos.
    add_index :tickets, [ :customer_id, :channel ], unique: true, where: "state <> 'fechado'",
              name: "index_tickets_one_open_per_customer_channel"
    # ADR-014: o atendimento é da marca do cliente.
    add_foreign_key :tickets, :customers, column: [ :customer_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_tickets_customer_same_brand"
    add_index :tickets, [ :id, :brand_id ], unique: true

    create_table :messages do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, null: false, foreign_key: true
      t.string :provider_account, null: false
      t.string :channel, null: false
      t.string :direction, null: false
      t.string :author_type, null: false
      t.bigint :author_id
      t.text :body, null: false
      t.boolean :internal, null: false, default: false
      t.string :external_id
      t.integer :seq, null: false
      t.string :trace_id, null: false
      t.string :subject
      t.jsonb :attachments, null: false, default: []
      t.jsonb :provider_payload
      t.datetime :received_at, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :messages, "direction IN ('inbound', 'outbound')", name: "messages_direction_check"
    add_check_constraint :messages, "author_type IN ('customer', 'bot', 'analyst', 'system')",
                         name: "messages_author_type_check"
    # RNF-15: o mesmo webhook do provedor vira uma mensagem só, no escopo da marca e da conta.
    add_index :messages, [ :brand_id, :provider_account, :channel, :external_id ], unique: true,
              where: "external_id IS NOT NULL", name: "index_messages_dedup_per_provider"
    add_index :messages, [ :ticket_id, :seq ], unique: true
    add_foreign_key :messages, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_messages_ticket_same_brand"

    # RN-54: só inserção. Sem updated_at.
    create_table :audit_events do |t|
      t.datetime :occurred_at, null: false, default: -> { "clock_timestamp()" }
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, foreign_key: true
      t.string :actor_type, null: false
      t.bigint :actor_id
      t.string :event_type, null: false
      t.jsonb :data, null: false, default: {}
      t.string :trace_id, null: false
      t.integer :ruleset_version
      t.string :agent_model
      t.string :agent_version
    end
    add_index :audit_events, [ :ticket_id, :occurred_at ]
    add_foreign_key :audit_events, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_audit_events_ticket_same_brand"
    # RN-54: nem a aplicação altera ou apaga. O REVOKE do papel da aplicação entra com infra/postgres (07, seção 4).
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION audit_events_immutable() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'auditoria é imutável (RN-54): registre um novo evento';
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER audit_events_immutable
            BEFORE UPDATE OR DELETE ON audit_events
            FOR EACH ROW EXECUTE FUNCTION audit_events_immutable();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER audit_events_immutable ON audit_events; DROP FUNCTION audit_events_immutable();"
      end
    end

    # id = event_id (07, seção 4; ADR-016).
    create_table :outbox_events, id: :uuid do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :ticket, foreign_key: true
      t.string :event_type, null: false
      t.string :dedup_key
      t.jsonb :payload, null: false
      t.string :trace_id, null: false
      t.datetime :created_at, null: false
      t.datetime :next_attempt_at, null: false
      t.datetime :lease_until
      t.datetime :published_at
      t.datetime :completed_at
    end
    add_index :outbox_events, :dedup_key, unique: true, where: "dedup_key IS NOT NULL"
    # Recuperação dos itens ainda abertos (07, seção 4).
    add_index :outbox_events, :next_attempt_at, where: "completed_at IS NULL", name: "index_outbox_events_open"
    add_foreign_key :outbox_events, :tickets, column: [ :ticket_id, :brand_id ], primary_key: [ :id, :brand_id ],
                    name: "fk_outbox_events_ticket_same_brand"
  end
end
