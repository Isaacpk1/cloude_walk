# Bloco 15 (RF-03, ADR-018): a conta de e-mail tem a caixa (`email_address`, que a notificação push traz) e o cursor do
# histórico já lido (`history_id`), para buscar só as mensagens novas em users.history.list.
class AddEmailFieldsToProviderAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :provider_accounts, :email_address, :string
    add_column :provider_accounts, :history_id, :bigint
    execute <<~SQL.squish
      UPDATE provider_accounts SET email_address = 'suporte@' || brands.slug || '.example'
      FROM brands WHERE brands.id = provider_accounts.brand_id AND provider_accounts.channel = 'email'
    SQL
    add_check_constraint :provider_accounts, "channel <> 'email' OR email_address IS NOT NULL", name: "provider_accounts_email_address_check"
  end
end
