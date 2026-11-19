# Versão imutável de uma fila (RN-20). Nunca é editada: mudanças criam outra versão.
class QueueVersion < ApplicationRecord
  belongs_to :queue, class_name: "HelpdeskQueue", inverse_of: :versions
  belongs_to :created_by, class_name: "User", optional: true

  validates :name, presence: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }

  def readonly? = persisted?
end
