# Processa um item do outbox (07, seção 2: fila critical). Recebe só o ID (docs/10, jobs; ADR-016)
# e delega ao service do tipo do item. Repetir o job é seguro: cada service confere o estado no banco.
#
# - "turn.dispatch": ação do scheduler no fim da janela de agrupamento (RN-55). Abre o turno
#   (Turns::Open) e acorda a publicação do evento do agente.
# - "agent.event": publica no broker (Outbox::Publish).
# - "delivery.requested": saída para o canal (Deliveries::Send; 07, seção 3.2). Uma retentativa
#   agendada volta como despertador no next_attempt_at do item.
# - "progress.notice": aviso de progresso do scheduler aos 15 s (RN-57). Turns::ProgressNotice revalida e grava a
#   saída do aviso; o envio é o delivery.requested seguinte. Relógio do banco antes do prazo: volta no prazo.
# - "message.received": aviso da ingestão. Não abre turno; fica para a triagem (bloco 11). Até lá, o
#   worker só o encerra, para a recuperação não reoferecê-lo para sempre.
#
# A espera de uma retentativa é só um despertador: o horário que vale é outbox_events.next_attempt_at,
# no Postgres. Se o Redis perder o job, a recuperação (Outbox::Recover) reoferece o item.
class OutboxJob < ApplicationJob
  queue_as :critical

  MESSAGE_RECEIVED = "message.received".freeze
  HANDLED = [ MESSAGE_RECEIVED, Turns::Open::DISPATCH_TYPE, Turns::Open::EVENT_TYPE, Deliveries::Send::EVENT_TYPE,
              Deadlines::ProgressDue::EVENT_TYPE ].freeze

  def perform(outbox_event_id)
    item = OutboxEvent.find_by(id: outbox_event_id)
    return unless item && item.completed_at.nil?

    case item.event_type
    when Turns::Open::DISPATCH_TYPE
      result = Turns::Open.call(item.id)
      self.class.perform_later(result.turn.event_id) if result.status == :opened
    when Turns::Open::EVENT_TYPE
      result = Outbox::Publish.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    when Deliveries::Send::EVENT_TYPE
      result = Deliveries::Send.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    when Deadlines::ProgressDue::EVENT_TYPE
      result = Turns::ProgressNotice.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    when MESSAGE_RECEIVED
      OutboxEvent.where(id: item.id, completed_at: nil).update_all(completed_at: Time.current, lease_until: nil)
    end
  end
end
