# Janela de agrupamento e teto do ciclo pendente (RN-55, RN-46; 06, parâmetros; 07, seção 3.4; ADR-020).
#
#   Turns::Window.dispatch_due_at(channel: "chat", now:, first_pending_at:, policy:)
#   Turns::Window.ai_deadline_at(first_pending_at:, policy:)
#
# O turno fica elegível ao fim da janela do canal depois da última mensagem (0 no e-mail) ou no teto
# desde a primeira mensagem pendente, o que vier primeiro, e nunca antes da gravação. O teto do ciclo
# conta desde a primeira mensagem pendente e não reinicia com mensagens novas. Os tempos vêm da
# Turns::Policy da marca.
module Turns
  module Window
    module_function

    # Nunca antes de `now`: depois do teto, o turno sai na próxima volta do scheduler, e o delay_ms
    # auditado mede o atraso real do scheduler, não o tempo desde o teto de um ciclo antigo.
    def dispatch_due_at(channel:, now:, first_pending_at:, policy: Policy::DEFAULT)
      [ [ now + policy.window_for(channel), first_pending_at + policy.ceiling ].min, now ].max
    end

    def ai_deadline_at(first_pending_at:, policy: Policy::DEFAULT) = first_pending_at + policy.cycle_deadline
  end
end
