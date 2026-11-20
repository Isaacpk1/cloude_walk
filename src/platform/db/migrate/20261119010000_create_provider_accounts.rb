# Contas dos provedores de canal (07, seções 4 e 5.0; ADR-019). Substituem o config/provider_accounts.yml:
# o supervisor cadastra marcas (RF-58), e a conta de canal ligada à marca precisa ser dado, com auditoria
# (RF-54) e chave estrangeira (invariante 8). O segredo fica criptografado pelo Active Record Encryption.
class CreateProviderAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_accounts do |t|
      t.references :brand, null: false, foreign_key: true
      t.string :channel, null: false
      # Identificador na URL: /webhooks/:channel/:slug.
      t.string :slug, null: false
      # WhatsApp: número da Meta ligado a esta URL. O corpo traz metadata.phone_number_id, que precisa bater.
      t.string :phone_number_id
      # Chat: segredo do HMAC (X-Helpdesk-Signature). WhatsApp: app secret (X-Hub-Signature-256).
      # E-mail: audiência do token do Pub/Sub. Cada adaptador confere do jeito do seu provedor.
      t.text :secret, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :provider_accounts, :slug, unique: true
    add_index :provider_accounts, :phone_number_id, unique: true, where: "phone_number_id IS NOT NULL"
    add_check_constraint :provider_accounts, "channel IN ('chat', 'whatsapp', 'email')", name: "provider_accounts_channel_check"
    add_check_constraint :provider_accounts, "channel <> 'whatsapp' OR phone_number_id IS NOT NULL",
                         name: "provider_accounts_whatsapp_phone_check"
  end
end
