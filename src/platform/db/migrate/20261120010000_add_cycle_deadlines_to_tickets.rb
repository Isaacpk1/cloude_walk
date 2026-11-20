# Bloco 03 (adiantado dos blocos 06 e 08): prazos do ciclo pendente no atendimento (07, seção 3.4; ADR-016).
# first_pending_seq/at marcam a primeira mensagem do cliente ainda sem resposta; dispatch_due_at é o fim da
# janela de agrupamento (RN-55); ai_deadline_at é o prazo da IA no ciclo (RN-46). O aviso de progresso
# (progress_due_at, RN-57) entra no bloco 08.
class AddCycleDeadlinesToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :first_pending_seq, :integer
    add_column :tickets, :first_pending_at, :datetime
    add_column :tickets, :dispatch_due_at, :datetime
    add_column :tickets, :ai_deadline_at, :datetime

    # Consulta do scheduler a cada 250 ms: só atendimentos com abertura de turno pendente (ADR-016).
    add_index :tickets, :dispatch_due_at, where: "dispatch_due_at IS NOT NULL", name: "index_tickets_dispatch_due"

    add_check_constraint :tickets, "first_pending_seq IS NULL OR first_pending_seq >= 1", name: "tickets_first_pending_seq_check"
    add_check_constraint :tickets, "(first_pending_seq IS NULL) = (first_pending_at IS NULL)", name: "tickets_first_pending_pair_check"
    add_check_constraint :tickets, "dispatch_due_at IS NULL OR first_pending_at IS NOT NULL", name: "tickets_dispatch_requires_cycle_check"
  end
end
