# Bloco 12 (RF-13, RF-17, RN-20): "excluir" fila é arquivar. As versões são imutáveis (o banco recusa DELETE) e os
# atendimentos antigos continuam apontando para ela, então a fila arquivada some das listas e das regras, mas fica.
class AddArchivedAtToQueues < ActiveRecord::Migration[8.0]
  def change
    add_column :queues, :archived_at, :datetime
  end
end
