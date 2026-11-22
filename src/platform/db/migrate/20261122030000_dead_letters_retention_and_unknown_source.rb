# Bloco 09 (B1): regras da DLQ da plataforma no banco (invariante 8; 07, seção 4, dead_letters).
#
# - RN-48, RNF-16: nada apaga um registro com menos de 7 dias. A limpeza dos antigos é pendência; quando
#   vier, o banco já garante o mínimo.
# - RF-34: mensagem com dlq_source ausente ou fora do contrato dead_letter é gravada como `unknown`, em vez de
#   sumir do espelho ou travar a partição (o check antigo recusaria a linha para sempre).
class DeadLettersRetentionAndUnknownSource < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :dead_letters, name: "dead_letters_source_check"
    add_check_constraint :dead_letters, "source IN ('broker', 'agent-mock', 'platform', 'unknown')",
                         name: "dead_letters_source_check"
    execute <<~SQL
      CREATE FUNCTION dead_letters_retention() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.created_at > now() - interval '7 days' THEN
          RAISE EXCEPTION 'dead_letters: retenção mínima de 7 dias (RN-48), registro %', OLD.id;
        END IF;
        RETURN OLD;
      END $$;
      CREATE TRIGGER dead_letters_retention BEFORE DELETE ON dead_letters
        FOR EACH ROW EXECUTE FUNCTION dead_letters_retention();
    SQL
  end

  def down
    execute "DROP TRIGGER dead_letters_retention ON dead_letters; DROP FUNCTION dead_letters_retention();"
    remove_check_constraint :dead_letters, name: "dead_letters_source_check"
    add_check_constraint :dead_letters, "source IN ('broker', 'agent-mock', 'platform')", name: "dead_letters_source_check"
  end
end
