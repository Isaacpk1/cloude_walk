# RF-52, ADR-027: um registro imutável para cada resolução do atendimento.
class TicketSummary < ApplicationRecord
  belongs_to :brand
  belongs_to :ticket

  def readonly? = persisted?
end
