# Medição do negócio simulado (ADR-029, bench/results/2026-11-24-negocio): as consultas de SLA do scheduler
# (Deadlines::SlaAlert e SlaBreach) rodam a cada tick sobre os casos aguardando humano sem analista e custaram
# ~33 ms em média, lendo a tabela de atendimentos inteira. O índice parcial cobre só esses casos, já na ordem
# do vencimento do SLA, e some do índice quando o caso é assumido, estoura o SLA ou sai da fila.
class AddSlaWaitingIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :tickets, %i[sla_due_at id], name: "index_tickets_sla_waiting",
                                           where: "state = 'aguardando_humano' AND assignee_id IS NULL AND sla_breached = false"
  end
end
