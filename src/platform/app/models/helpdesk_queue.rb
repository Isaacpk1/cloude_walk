# Fila de atendimento. A identidade é estável; nome, IA primeiro e SLA ficam
# em versões imutáveis (RN-20, RF-18). Chama-se HelpdeskQueue porque `Queue`
# já é uma classe do Ruby.
class HelpdeskQueue < ApplicationRecord
  self.table_name = "queues"

  belongs_to :brand
  belongs_to :team
  belongs_to :current_version, class_name: "QueueVersion", optional: true
  has_many :versions, -> { order(:version) }, class_name: "QueueVersion",
                                              foreign_key: :queue_id, inverse_of: :queue, dependent: :restrict_with_exception

  validate :team_from_same_brand

  # Cria uma versão nova e passa a apontar para ela. A linha da fila é travada
  # para que duas edições simultâneas recebam números seguidos (RN-20).
  def publish_version!(name:, created_by:, ai_first: true, sla_policy: {}, business_hours: {})
    with_lock do
      next_number = versions.maximum(:version).to_i + 1
      version = versions.create!(version: next_number, name:, ai_first:, sla_policy:, business_hours:, created_by:)
      update!(current_version: version)
      version
    end
  end

  private

  def team_from_same_brand
    return if team.nil? || team.brand_id == brand_id

    errors.add(:team, "deve ser da mesma marca da fila")
  end
end
