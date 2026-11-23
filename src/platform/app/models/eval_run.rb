# Execução de um eval (07, seção 4; ADR-023). Só inserção: o banco recusa UPDATE e DELETE.
class EvalRun < ApplicationRecord
  STATUSES = %w[passed failed error].freeze

  belongs_to :brand
  belongs_to :ticket, optional: true

  validates :scenario, :agent_model, :agent_version, :started_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  def readonly? = persisted?
end
