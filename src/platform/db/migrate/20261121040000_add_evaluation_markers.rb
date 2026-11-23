# Bloco 07 (ADR-023, item 5): o atendimento do eval é marcado de forma durável no commit da primeira mensagem,
# para o worker não publicar o turno dele no broker nem entregar a saída dele ao canal.
#
# - provider_accounts.evaluation: a conta de provedor é de eval (uma por marca, criada inativa: nenhum webhook
#   entra por ela; só o executor do eval grava mensagens com ela).
# - tickets.evaluation: gravada pela ingestão na criação do atendimento, a partir da conta. Não muda depois
#   (trigger): um atendimento real nunca vira eval, nem um eval vira real (invariante 8).
class AddEvaluationMarkers < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_accounts, :evaluation, :boolean, null: false, default: false
    add_column :tickets, :evaluation, :boolean, null: false, default: false

    execute <<~SQL
      CREATE FUNCTION tickets_evaluation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'tickets.evaluation não muda depois da criação';
      END;
      $$;

      CREATE TRIGGER tickets_evaluation_immutable BEFORE UPDATE OF evaluation ON tickets
        FOR EACH ROW WHEN (NEW.evaluation IS DISTINCT FROM OLD.evaluation)
        EXECUTE FUNCTION tickets_evaluation_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER tickets_evaluation_immutable ON tickets;
      DROP FUNCTION tickets_evaluation_immutable();
    SQL
    remove_column :tickets, :evaluation
    remove_column :provider_accounts, :evaluation
  end
end
