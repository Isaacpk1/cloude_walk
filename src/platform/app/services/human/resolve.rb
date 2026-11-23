# Resolução pelo analista (RF-48; 07, seção 3.6): motivo obrigatório de uma lista fixa, texto de encerramento opcional
# (entrega `resolution`), caso em `resolvido` e vaga do analista liberada (RN-30), tudo na mesma transação com o
# atendimento travado. A segunda tentativa encontra o caso fora de `com_analista` e é recusada: a vaga sai uma vez só.
module Human
  class Resolve < Action
    REASONS = %w[duvida_respondida problema_resolvido sem_resposta_do_cliente outro].freeze

    private

    def validate = REASONS.include?(@rest[:reason].to_s) ? nil : "motivo_invalido"

    def perform
      event = closing_delivery
      state_from = @ticket.state
      @ticket.update_columns(state: "resolvido", updated_at: @now)
      Distribution::Slot.release!(user_id: @user.id)
      audit("ticket.resolved", reason: @rest[:reason].to_s, state_from:, state_to: "resolvido", queue_id: @ticket.queue_id,
                               assignment_version: @ticket.assignment_version)
      Result.new(status: :resolved, delivery_event_id: event&.id)
    end

    def closing_delivery
      text = @rest[:text].to_s.strip
      return if text.empty?

      message = create_message(text, internal: false)
      _delivery, event = request_delivery(message, kind: "resolution")
      event
    end
  end
end
