# Janela de agrupamento e prazos do ciclo pendente (RN-55, RN-46; 06, parâmetros; 07, seção 3.4).
#
#   Turns::Window.dispatch_due_at(channel: "chat", now:, first_pending_at:)
#   Turns::Window.ai_deadline_at(first_pending_at:)
#
# O turno fica elegível 1,5 s depois da última mensagem (0 no e-mail) ou 4 s depois da primeira
# mensagem pendente, o que vier primeiro, e nunca antes da gravação. O prazo da IA conta 30 s desde a primeira mensagem
# pendente e não reinicia com mensagens novas.
module Turns
  module Window
    BY_CHANNEL = {
      "chat" => 1.5.seconds,
      "whatsapp" => 1.5.seconds,
      "email" => 0.seconds
    }.freeze
    CEILING = 4.seconds # RN-55
    AI_DEADLINE = 30.seconds # RN-46

    module_function

    # Canal desconhecido é erro: uma janela padrão esconderia um canal novo sem parâmetro definido.
    def for(channel) = BY_CHANNEL.fetch(channel)

    # Nunca antes de `now`: depois do teto, o turno sai na próxima volta do scheduler, e o delay_ms
    # auditado mede o atraso real do scheduler, não o tempo desde o teto de um ciclo antigo.
    def dispatch_due_at(channel:, now:, first_pending_at:)
      [ [ now + self.for(channel), first_pending_at + CEILING ].min, now ].max
    end

    def ai_deadline_at(first_pending_at:) = first_pending_at + AI_DEADLINE
  end
end
