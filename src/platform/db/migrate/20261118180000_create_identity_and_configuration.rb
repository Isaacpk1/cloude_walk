# Tabelas de identidade e configuração do bloco 01 (07, seção 4).
# Restrições que carregam regra de negócio ficam no banco (invariante 8).
class CreateIdentityAndConfiguration < ActiveRecord::Migration[8.1]
  def change
    create_table :brands do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :locale, null: false, default: "pt-BR"
      t.string :timezone, null: false, default: "America/Sao_Paulo"
      t.timestamps
    end
    add_index :brands, :slug, unique: true

    create_table :teams do |t|
      t.references :brand, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :teams, [ :brand_id, :name ], unique: true

    # RF-23: o agente de IA é um user do tipo bot (P4).
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :kind, null: false, default: "human"
      t.string :role, null: false, default: "analyst"
      t.string :status, null: false, default: "offline"
      t.integer :capacity, null: false, default: 5 # RN-30
      t.integer :active_count, null: false, default: 0
      t.timestamps
    end
    add_index :users, :email, unique: true
    add_check_constraint :users, "kind IN ('human', 'bot')", name: "users_kind_check"
    add_check_constraint :users, "role IN ('supervisor', 'analyst', 'agent')", name: "users_role_check"
    add_check_constraint :users, "status IN ('online', 'pausa', 'offline')", name: "users_status_check"
    add_check_constraint :users, "active_count >= 0 AND active_count <= capacity", name: "users_capacity_check"

    # RN-52: daqui sai o escopo de acesso por marca e equipe.
    create_table :team_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :team, null: false, foreign_key: true
      t.timestamps
    end
    add_index :team_memberships, [ :user_id, :team_id ], unique: true

    # RN-01: cliente pertence a exatamente uma marca. RN-05: verified.
    create_table :customers do |t|
      t.references :brand, null: false, foreign_key: true
      t.string :display_name, null: false
      t.boolean :verified, null: false, default: false
      t.timestamps
    end

    # RN-02: um identificador pertence a um só cliente dentro da marca.
    create_table :customer_identities do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.string :channel, null: false
      t.string :external_id, null: false
      t.timestamps
    end
    add_index :customer_identities, [ :brand_id, :channel, :external_id ], unique: true,
              name: "index_customer_identities_unique_per_brand"
    add_check_constraint :customer_identities, "channel IN ('chat', 'whatsapp', 'email')",
                         name: "customer_identities_channel_check"

    # Identidade estável da fila; os atributos editáveis ficam na versão (RN-20).
    create_table :queues do |t|
      t.references :brand, null: false, foreign_key: true
      t.references :team, null: false, foreign_key: true
      t.bigint :current_version_id
      t.boolean :is_default, null: false, default: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :queues, :brand_id, unique: true, where: "is_default", name: "index_queues_one_default_per_brand"

    create_table :queue_versions do |t|
      t.references :queue, null: false, foreign_key: true
      t.integer :version, null: false
      t.string :name, null: false
      t.boolean :ai_first, null: false, default: true
      t.jsonb :sla_policy, null: false, default: {}
      t.jsonb :business_hours, null: false, default: {}
      t.references :created_by, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    add_index :queue_versions, [ :queue_id, :version ], unique: true
    add_foreign_key :queues, :queue_versions, column: :current_version_id
  end
end
