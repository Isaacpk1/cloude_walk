# Atendentes humanos pelo supervisor (bloco 12; RF-22, RN-53, RN-54, RNF-26): usuário com senha (bcrypt), perfil
# analista ou supervisor, capacidade e equipe da marca. A auditoria nunca leva a senha.
module Configuration
  class Analysts
    ROLES = %w[analyst supervisor].freeze
    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    def self.create(brand:, team_id:, name:, email:, role:, password:, capacity:, created_by:)
      email = email.to_s.strip.downcase
      team = Team.find_by(id: team_id, brand_id: brand.id)
      errors = validate(name:, email:, role:, password:, capacity:)
      errors << "a equipe não existe nesta marca" unless team
      errors << "já existe um usuário com esse e-mail" if errors.empty? && User.exists?(email:)
      return Queues::Result.failure(errors) if errors.any?

      ActiveRecord::Base.transaction do
        user = User.create!(name: name.strip, email:, kind: "human", role:, status: "offline", capacity: capacity.to_i, password:)
        TeamMembership.create!(user:, team:)
        AuditEvent.create!(brand_id: brand.id, ticket_id: nil, actor_type: "user", actor_id: created_by&.id, event_type: "analyst.created",
                           trace_id: SecureRandom.hex(16), data: { user_id: user.id, role:, team_id: team.id, capacity: user.capacity })
        Queues::Result.success(user)
      end
    end

    def self.validate(name:, email:, role:, password:, capacity:)
      errors = []
      errors << "o nome é obrigatório" if name.to_s.strip.empty?
      errors << "e-mail inválido" unless email.match?(EMAIL)
      errors << "perfil inválido" unless ROLES.include?(role.to_s)
      errors << "a senha precisa de pelo menos 10 caracteres" if password.to_s.length < 10
      errors << "a capacidade deve ser um inteiro entre 1 e 50" unless capacity.to_s.match?(/\A\d+\z/) && capacity.to_i.between?(1, 50)
      errors
    end
    private_class_method :validate
  end
end
