module Configuration
  class AiPolicies
    FIELDS = %w[chat_window whatsapp_window email_window ceiling turn_deadline cycle_deadline progress_notice].freeze

    def self.publish(brand:, attributes:, created_by:)
      unless created_by&.supervisor? && created_by.brand_ids_in_scope.include?(brand.id)
        return Queues::Result.failure([ "sem acesso à marca" ])
      end
      brand.with_lock do
        previous = AiPolicyVersion.current_for(brand)
        values = (previous&.settings || Turns::Policy::DEFAULT.to_snapshot.slice(*FIELDS)).merge(attributes.stringify_keys)
        errors = validate(values)
        next Queues::Result.failure(errors) if errors.any?

        version = AiPolicyVersion.create!(brand:, version: previous ? previous.version + 1 : 1,
                                          settings: values.transform_values { Float(_1) }, created_by:, created_at: Time.current)
        AuditEvent.create!(brand:, actor_type: "user", actor_id: created_by.id, event_type: "ai_policy.published",
                           trace_id: SecureRandom.hex(16), data: { version: version.version, settings: version.settings })
        Queues::Result.success(version)
      end
    end

    def self.validate(values)
      return [ "campos dos tempos da IA inválidos" ] unless values.keys.sort == FIELDS.sort

      numbers = values.transform_values { Float(_1, exception: false) }
      return [ "informe tempos numéricos finitos em segundos" ] unless numbers.values.all? { _1&.finite? }

      turn = numbers.fetch("turn_deadline")
      cycle = numbers.fetch("cycle_deadline")
      ceiling = numbers.fetch("ceiling")
      valid = turn.between?(5, 60) && cycle.between?(turn, 300) && numbers["progress_notice"].positive? &&
              numbers["progress_notice"] < cycle && ceiling.between?(0, 4) &&
              %w[chat_window whatsapp_window email_window].all? { numbers[_1].between?(0, ceiling) }
      valid ? [] : [ "turno: 5 a 60 s; ciclo: entre o turno e 300 s; aviso: antes do ciclo; janelas: de 0 até o teto de no máximo 4 s" ]
    end
  end
end
