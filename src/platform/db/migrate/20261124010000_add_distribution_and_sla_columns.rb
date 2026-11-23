# Bloco 13: distribuição humana (RN-30, RN-31) e prazos de SLA (RN-21 a RN-26, RN-29).
#
# users: `status_changed_at` marca quando a disponibilidade mudou (desde quando está offline, RN-31) e
# `last_assigned_at` desempata a distribuição ("quem está há mais tempo sem receber caso", RN-30).
# tickets: o prazo de assunção após escalação fica na linha (ADR-016): `sla_started_at` é a entrada na fila humana
# e nunca é reiniciado (RN-23, RN-32); `sla_due_at` é o prazo da política da fila para a prioridade; `sla_alerted_at`
# marca o aviso dos 80% (RN-25) e `sla_breached` o estouro, permanente (RN-26).
class AddDistributionAndSlaColumns < ActiveRecord::Migration[8.0]
  def change
    change_table :users, bulk: true do |t|
      t.datetime :status_changed_at, precision: 6
      t.datetime :last_assigned_at, precision: 6
    end

    change_table :tickets, bulk: true do |t|
      t.datetime :sla_started_at, precision: 6
      t.datetime :sla_due_at, precision: 6
      t.datetime :sla_alerted_at, precision: 6
      t.boolean :sla_breached, null: false, default: false
    end

    add_check_constraint :tickets, "(sla_due_at IS NULL) OR (sla_started_at IS NOT NULL AND sla_due_at >= sla_started_at)",
                         name: "tickets_sla_due_after_start_check"
    add_check_constraint :tickets, "(sla_alerted_at IS NULL) OR (sla_started_at IS NOT NULL)",
                         name: "tickets_sla_alert_requires_start_check"

    # RN-29: a fila humana lê os casos esperando, por marca, na ordem prioridade, prazo e chegada (RNF-08).
    add_index :tickets, %i[brand_id queue_id priority sla_due_at id], name: "index_tickets_human_queue_order",
                                                                      where: "state = 'aguardando_humano'"
    # RN-31: o scheduler encontra os casos de analista offline sem varrer a tabela.
    add_index :tickets, %i[brand_id assignee_id], name: "index_tickets_analyst_cases",
                                                  where: "state IN ('com_analista', 'aguardando_cliente') AND assignee_id IS NOT NULL"
    # RN-30: candidatos da distribuição.
    add_index :users, %i[status active_count last_assigned_at], name: "index_users_distribution",
                                                                where: "kind = 'human' AND role = 'analyst'"
  end
end
