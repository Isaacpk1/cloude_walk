# Turno enviado ao agente (07, seção 3.4; RN-55 a RN-57). Guarda o que a IA recebeu e,
# a partir do bloco 04, o que ela devolveu. `applied`, `superseded` e `expired` são terminais.
class AiTurn < ApplicationRecord
  STATUSES = %w[eligible applied superseded expired].freeze

  belongs_to :brand
  belongs_to :ticket, inverse_of: :ai_turns

  validates :status, inclusion: { in: STATUSES }

  scope :eligible, -> { where(status: "eligible") }

  def eligible? = status == "eligible"
end
