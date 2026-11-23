# Bloco 14 (ADR-024; RNF-26): senha com hash bcrypt para o login do painel. Nula para o bot, que não entra no painel.
class AddPasswordDigestToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :password_digest, :string
  end
end
