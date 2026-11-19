# Processa um item do outbox (07, seção 2: fila critical). Recebe só o ID (docs/10, jobs; ADR-016)
# e delega ao service do tipo do item. Repetir o job é seguro: cada service confere o estado no banco.
#
# A espera de uma retentativa é só um despertador: o horário que vale é outbox_events.next_attempt_at,
# no Postgres. Se o Redis perder o job, a recuperação (Outbox::Recover) reoferece o item.
class OutboxJob < ApplicationJob
  queue_as :critical

  def perform(outbox_event_id)
    item = OutboxEvent.find_by(id: outbox_event_id)
    return unless item && item.completed_at.nil?

    case item.event_type
    when "message.received"
      result = Turns::Open.call(item.id)
      self.class.perform_later(result.turn.event_id) if result.status == :opened
    when Turns::Open::EVENT_TYPE
      result = Outbox::Publish.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    end
  end
end
