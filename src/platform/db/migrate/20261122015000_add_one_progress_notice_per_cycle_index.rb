# RN-57 e invariante 8: um aviso de progresso por ciclo também no banco (além da chave do outbox e do lock).
class AddOneProgressNoticePerCycleIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :deliveries, %i[ticket_id ai_first_pending_seq], unique: true, where: "kind = 'progress'",
                                                               name: "index_deliveries_one_progress_per_cycle"
  end
end
