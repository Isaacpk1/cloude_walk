# Leva ao banco regras que antes só existiam em Ruby (invariante 8, ADR-014, RN-20).
class EnforceBrandIntegrity < ActiveRecord::Migration[8.1]
  def up
    # A marca da identidade é a marca do cliente (RN-01, RN-02).
    add_index :customers, [ :id, :brand_id ], unique: true
    add_foreign_key :customer_identities, :customers, column: [ :customer_id, :brand_id ],
                    primary_key: [ :id, :brand_id ], name: "fk_customer_identities_same_brand"

    # A fila e a equipe que a atende são da mesma marca (RF-58).
    add_index :teams, [ :id, :brand_id ], unique: true
    add_foreign_key :queues, :teams, column: [ :team_id, :brand_id ],
                    primary_key: [ :id, :brand_id ], name: "fk_queues_team_same_brand"

    # A versão atual de uma fila é sempre uma versão dela (RN-20).
    add_index :queue_versions, [ :id, :queue_id ], unique: true
    remove_foreign_key :queues, column: :current_version_id
    add_foreign_key :queues, :queue_versions, column: [ :current_version_id, :id ],
                    primary_key: [ :id, :queue_id ], name: "fk_queues_current_version_of_queue"

    # Versão publicada não muda nem some (RN-20, invariante 9).
    execute <<~SQL
      CREATE FUNCTION queue_versions_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'versão de fila é imutável (RN-20): crie uma versão nova';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER queue_versions_immutable
        BEFORE UPDATE OR DELETE ON queue_versions
        FOR EACH ROW EXECUTE FUNCTION queue_versions_immutable();
    SQL
  end

  def down
    execute "DROP TRIGGER queue_versions_immutable ON queue_versions; DROP FUNCTION queue_versions_immutable();"
    remove_foreign_key :queues, name: "fk_queues_current_version_of_queue"
    add_foreign_key :queues, :queue_versions, column: :current_version_id
    remove_index :queue_versions, [ :id, :queue_id ]
    remove_foreign_key :queues, name: "fk_queues_team_same_brand"
    remove_index :teams, [ :id, :brand_id ]
    remove_foreign_key :customer_identities, name: "fk_customer_identities_same_brand"
    remove_index :customers, [ :id, :brand_id ]
  end
end
