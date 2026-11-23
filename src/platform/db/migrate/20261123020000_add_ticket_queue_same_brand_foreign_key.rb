# Invariantes 6 e 8, RN-15: a fila do atendimento é da mesma marca, garantido pelo banco (revisão do bloco 11). Usa o
# índice único queues (id, brand_id) criado com os conjuntos de regras.
class AddTicketQueueSameBrandForeignKey < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :tickets, :queues, column: :queue_id
    add_foreign_key :tickets, :queues, column: %i[queue_id brand_id], primary_key: %i[id brand_id],
                                       name: "fk_tickets_queue_same_brand"
  end
end
