# Bloco 08: o scheduler consulta a cada 250 ms os turnos eligible com o prazo vencido (Deadlines::TurnTimeout;
# RN-46, ADR-016, ADR-020). O índice parcial cobre só os turnos ainda abertos, que são poucos.
class AddEligibleTurnDeadlineIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :ai_turns, :deadline_at, where: "status = 'eligible'", name: "index_ai_turns_eligible_deadline"
  end
end
