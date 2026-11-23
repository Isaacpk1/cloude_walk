# Resumo do handoff (RN-39, RN-40; 07, seção 3.2): os cinco campos, vindos do agente (`escalate`) ou montados
# pela plataforma a partir do histórico; ou "sem resumo", com o motivo. Um por handoff, só inserção.
class HandoffSummary < ApplicationRecord
  SOURCES = %w[agent platform].freeze
  STATUSES = %w[available missing].freeze
  FIELDS = %w[problema dados_cliente acoes_tomadas motivo pendente].freeze

  belongs_to :brand
  belongs_to :ticket

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }

  def readonly? = persisted?
end
