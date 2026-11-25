module Configuration
  class Brands
    def self.create(attributes:, created_by:)
      return Queues::Result.failure([ "somente supervisor cadastra marcas" ]) unless created_by&.supervisor?

      attrs = attributes.symbolize_keys.slice(:name, :slug, :locale, :timezone).transform_values { _1.to_s.strip }
      errors = []
      errors << "nome obrigatório, com até 120 caracteres" unless attrs[:name].present? && attrs[:name].length <= 120
      errors << "slug inválido" unless attrs[:slug].to_s.match?(/\A[a-z][a-z0-9-]{0,62}\z/)
      errors << "idioma deve ser pt-BR ou en" unless %w[pt-BR en].include?(attrs[:locale])
      errors << "fuso horário inválido" unless ActiveSupport::TimeZone[attrs[:timezone].to_s]
      return Queues::Result.failure(errors) if errors.any?

      ActiveRecord::Base.transaction do
        brand = Brand.create!(**attrs)
        team = Team.create!(brand:, name: "Operação")
        TeamMembership.create!(team:, user: created_by)
        bot = User.create!(name: "Agente #{brand.name}", email: "bot.#{brand.slug}@helpdesk.test", kind: "bot",
                           role: "agent", status: "online", capacity: 1000)
        TeamMembership.create!(team:, user: bot)
        [ [ "Geral", true, false ], [ "Escalas N1", false, true ] ].each do |name, default, escalation|
          queue = HelpdeskQueue.create!(brand:, team:, is_default: default, escalation:, active: true)
          queue.publish_version!(name:, ai_first: default, created_by:)
          audit(brand, created_by, "queue.created", queue_id: queue.id, version: 1)
        end
        audit(brand, created_by, "brand.created", name: brand.name, slug: brand.slug, locale: brand.locale, timezone: brand.timezone)
        audit(brand, created_by, "team.created", team_id: team.id, name: team.name)
        audit(brand, created_by, "agent.created", user_id: bot.id)
        Queues::Result.success(brand)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Queues::Result.failure([ "não foi possível cadastrar: confira o slug único e os dados da marca" ])
    end

    def self.audit(brand, user, event_type, **data)
      AuditEvent.create!(brand:, actor_type: "user", actor_id: user.id, event_type:, trace_id: SecureRandom.hex(16), data:)
    end
  end
end
