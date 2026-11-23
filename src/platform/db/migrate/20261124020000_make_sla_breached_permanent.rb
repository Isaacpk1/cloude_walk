# RN-26: o estouro do SLA é permanente. Regra crítica vira restrição de banco (invariante 8): nenhum código, nem
# um erro dele, desmarca `tickets.sla_breached`.
class MakeSlaBreachedPermanent < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE FUNCTION tickets_sla_breached_permanent() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.sla_breached AND NOT NEW.sla_breached THEN
          RAISE EXCEPTION 'tickets.sla_breached é permanente (RN-26): atendimento %', OLD.id;
        END IF;
        RETURN NEW;
      END $$;
    SQL
    execute <<~SQL
      CREATE TRIGGER tickets_sla_breached_permanent BEFORE UPDATE OF sla_breached ON tickets
        FOR EACH ROW EXECUTE FUNCTION tickets_sla_breached_permanent();
    SQL
  end

  def down
    execute "DROP TRIGGER tickets_sla_breached_permanent ON tickets"
    execute "DROP FUNCTION tickets_sla_breached_permanent()"
  end
end
