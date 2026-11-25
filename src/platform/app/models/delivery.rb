# Entrega de uma mensagem de saída ao canal de origem (07, seções 3.2 e 4; RF-06). O delivery_id é
# estável nas retentativas e é a chave de idempotência no provedor (RNF-15).
class Delivery < ApplicationRecord
  STATUSES = %w[pending sending delivered cancelled failed].freeze
  OPEN = %w[pending sending].freeze
  KINDS = %w[reply resolution progress handoff_notice analyst reminder].freeze

  belongs_to :brand
  belongs_to :ticket
  belongs_to :message

  scope :open, -> { where(status: OPEN) }

  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }
end
