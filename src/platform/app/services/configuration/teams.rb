# Equipes pelo supervisor (bloco 12; RF-58, RN-53, invariantes 6 e 7): equipe sempre dentro de uma marca, com nome único
# na marca (sem diferenciar maiúsculas), auditada na mesma transação.
module Configuration
  class Teams
    def self.create(brand:, name:, created_by:)
      name = name.to_s.strip
      errors = []
      errors << "o nome é obrigatório" if name.empty?
      errors << "o nome tem no máximo 120 caracteres" if name.length > 120
      errors << "já existe uma equipe com esse nome na marca" if name.present? && Team.where(brand_id: brand.id).where("lower(name) = ?", name.downcase).exists?
      return Queues::Result.failure(errors) if errors.any?

      ActiveRecord::Base.transaction do
        team = Team.create!(brand:, name:)
        AuditEvent.create!(brand_id: brand.id, ticket_id: nil, actor_type: "user", actor_id: created_by&.id, event_type: "team.created",
                           trace_id: SecureRandom.hex(16), data: { team_id: team.id, name: })
        Queues::Result.success(team)
      end
    end
  end
end
