# Filas pelo supervisor (bloco 12; RF-13, RF-17, RF-18, RF-54, RN-20, RN-53; invariantes 6, 7, 9). A fila tem identidade
# estável e versões imutáveis (nome, IA primeiro, SLA): editar publica uma versão nova sob a trava da fila. Toda
# operação filtra pela marca, valida em texto o que o supervisor vê, e audita na mesma transação (`ticket_id` nulo).
#
#   Configuration::Queues.create(brand:, team_id:, name:, created_by:, ai_first: true, sla_policy: {})
#   Configuration::Queues.update(brand:, queue_id:, name:, ai_first:, sla_policy:, created_by:)
#   Configuration::Queues.set_active(brand:, queue_id:, active:, created_by:)
#   Configuration::Queues.destroy(brand:, queue_id:, created_by:)
#   # => Result(ok:, record:, errors:)
module Configuration
  class Queues
    Result = Data.define(:ok, :record, :errors) do
      def self.success(record = nil) = new(ok: true, record:, errors: [])
      def self.failure(*errors) = new(ok: false, record: nil, errors: errors.flatten)
    end
    SLA_FIELDS = %w[first_response_s assume_s resolve_s].freeze
    NAME_LIMIT = 120

    class << self
      def create(brand:, team_id:, name:, created_by:, ai_first: true, sla_policy: {})
        errors = validate(name, sla_policy)
        team = Team.find_by(id: team_id, brand_id: brand.id)
        errors << "a equipe não existe nesta marca" unless team
        return Result.failure(errors) if errors.any?

        ActiveRecord::Base.transaction do
          queue = HelpdeskQueue.create!(brand:, team:)
          version = queue.publish_version!(name: name.strip, ai_first:, sla_policy:, created_by:)
          audit(brand, created_by, "queue.created", queue_id: queue.id, version: version.version, name: version.name,
                                                    team_id: team.id, ai_first:, sla_policy:)
          Result.success(queue.reload)
        end
      end

      def update(brand:, queue_id:, name:, ai_first:, sla_policy:, created_by:)
        errors = validate(name, sla_policy)
        return Result.failure(errors) if errors.any?

        ActiveRecord::Base.transaction do
          queue = HelpdeskQueue.where(brand_id: brand.id, archived_at: nil).lock.find_by(id: queue_id)
          next Result.failure("a fila não existe nesta marca") unless queue

          before = queue.current_version
          version = queue.publish_version!(name: name.strip, ai_first:, sla_policy:, created_by:)
          audit(brand, created_by, "queue.version_published", queue_id: queue.id, version: version.version,
                                                              changes: changes(before, version))
          Result.success(queue.reload)
        end
      end

      def set_active(brand:, queue_id:, active:, created_by:)
        ActiveRecord::Base.transaction do
          queue = HelpdeskQueue.where(brand_id: brand.id, archived_at: nil).lock.find_by(id: queue_id)
          next Result.failure("a fila não existe nesta marca") unless queue

          errors = active ? [] : protected_reasons(brand, queue, "desativar")
          next Result.failure(errors) if errors.any?

          queue.update!(active:)
          audit(brand, created_by, active ? "queue.activated" : "queue.deactivated", queue_id: queue.id)
          Result.success(queue)
        end
      end

      # "Excluir" arquiva (RF-13): as versões são imutáveis e os atendimentos antigos continuam apontando para a fila.
      # RF-17: só sem atendimento aberto (qualquer estado que não seja resolvido ou fechado).
      def destroy(brand:, queue_id:, created_by:)
        ActiveRecord::Base.transaction do
          queue = HelpdeskQueue.where(brand_id: brand.id, archived_at: nil).lock.find_by(id: queue_id)
          next Result.failure("a fila não existe nesta marca") unless queue

          errors = protected_reasons(brand, queue, "excluir")
          open_tickets = Ticket.where(brand_id: brand.id, queue_id: queue.id).where.not(state: %w[resolvido fechado]).count
          errors << "a fila tem #{open_tickets} atendimento(s) aberto(s)" if open_tickets.positive?
          next Result.failure(errors) if errors.any?

          queue.update!(archived_at: Time.current, active: false)
          audit(brand, created_by, "queue.deleted", queue_id: queue.id, name: queue.current_version&.name)
          Result.success(queue)
        end
      end

      private

      def validate(name, sla_policy)
        errors = []
        errors << "o nome é obrigatório" if name.to_s.strip.empty?
        errors << "o nome tem no máximo #{NAME_LIMIT} caracteres" if name.to_s.length > NAME_LIMIT
        errors + sla_errors(sla_policy)
      end

      def sla_errors(policy)
        return [ "o SLA deve ser um conjunto de prioridades" ] unless policy.is_a?(Hash)

        policy.flat_map do |priority, values|
          next [ "SLA: prioridade desconhecida: #{priority}" ] unless Handoff::Policy::PRIORITIES.include?(priority.to_s)
          next [ "SLA #{priority}: informe os prazos em segundos" ] unless values.is_a?(Hash)

          values.flat_map do |field, seconds|
            if SLA_FIELDS.exclude?(field.to_s) then [ "SLA #{priority}: campo desconhecido: #{field}" ]
            elsif !seconds.is_a?(Integer) || seconds <= 0 then [ "SLA #{priority}.#{field}: deve ser um inteiro positivo (segundos)" ]
            else []
            end
          end
        end
      end

      # RF-17: o que não pode sair de uso (fila padrão, de escalas, ou apontada pelo conjunto de regras atual).
      def protected_reasons(brand, queue, verb)
        reasons = []
        reasons << "não é possível #{verb} a fila padrão da marca" if queue.is_default
        reasons << "não é possível #{verb} a fila de escalas da marca" if queue.escalation
        ruleset = RoutingRuleset.current_for(brand)
        used = ruleset && (ruleset.default_queue_id == queue.id || ruleset.rules["rules"].any? { _1["queue_id"] == queue.id })
        reasons << "a fila é usada pelas regras de roteamento atuais: troque a regra antes de #{verb}" if used
        reasons
      end

      def changes(before, after)
        { "name" => [ before&.name, after.name ], "ai_first" => [ before&.ai_first, after.ai_first ],
          "sla_policy" => [ before&.sla_policy, after.sla_policy ] }.reject { |_, (from, to)| from == to }
      end

      def audit(brand, user, event_type, **data)
        AuditEvent.create!(brand_id: brand.id, ticket_id: nil, actor_type: "user", actor_id: user&.id, event_type:,
                           trace_id: SecureRandom.hex(16), data:)
      end
    end
  end
end
