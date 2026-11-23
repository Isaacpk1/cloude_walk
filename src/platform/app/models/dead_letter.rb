# Espelho de uma mensagem do tópico de DLQ (07, seção 4; RF-37, RN-45, RN-48).
class DeadLetter < ApplicationRecord
  SOURCES = %w[broker agent-mock platform].freeze
  OUTCOMES = %w[escalated audited uncorrelated].freeze

  belongs_to :brand, optional: true
  belongs_to :ticket, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
end
