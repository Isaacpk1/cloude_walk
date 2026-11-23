# Processa um item do outbox (07, seção 2: fila critical). Recebe só o ID (docs/10, jobs; ADR-016)
# e delega ao service do tipo do item. Repetir o job é seguro: cada service confere o estado no banco.
#
# - "turn.dispatch": ação do scheduler no fim da janela de agrupamento (RN-55). Abre o turno
#   (Turns::Open) e acorda a publicação do evento do agente.
# - "agent.event": publica no broker (Outbox::Publish).
# - "delivery.requested": saída para o canal (Deliveries::Send; 07, seção 3.2). Uma retentativa
#   agendada volta como despertador no next_attempt_at do item.
# - "turn.timeout" e "cycle.timeout": prazos do turno e do ciclo vencidos (RN-46, ADR-020). Deadlines::Expire
#   revalida, expira o turno e pede o handoff; o pedido é acordado aqui, depois do commit.
# - "handoff.requested": pedido de handoff de qualquer gatilho (Handoff::Escalate; interface do bloco 08). Acorda,
#   depois do commit, o aviso de transferência (delivery.requested) e o pedido de resumo (handoff.summary) gravados.
#   Turns::Open e Outbox::Publish também podem pedir o handoff (falha definitiva, RN-46 e RN-49).
# - "progress.notice": aviso de progresso do scheduler aos 15 s (RN-57). Turns::ProgressNotice revalida e grava a
#   saída do aviso; o envio é o delivery.requested seguinte. Relógio do banco antes do prazo: volta no prazo.
# - "handoff.summary": resumo do handoff montado pela plataforma quando o agente não mandou o dele (RN-39, RN-40;
#   Handoff::Summarize). Grava o resumo ou o "sem resumo" e conclui o item; nunca mexe no handoff.
# - "message.received": aviso da ingestão. Triage::OnMessage trava o atendimento, faz a triagem do caso novo
#   (RF-12, RF-24, RN-28; 07, seção 3.1, passo 2) e conclui o item na mesma transação. Não abre turno: o turno sai
#   pelo scheduler, quando dispatch_due_at vence. Erro na triagem deixa o item aberto para a recuperação.
#
# A espera de uma retentativa é só um despertador: o horário que vale é outbox_events.next_attempt_at,
# no Postgres. Se o Redis perder o job, a recuperação (Outbox::Recover) reoferece o item.
class OutboxJob < ApplicationJob
  queue_as :critical

  MESSAGE_RECEIVED = Triage::OnMessage::EVENT_TYPE
  TIMEOUTS = [ Deadlines::TurnTimeout::EVENT_TYPE, Deadlines::CycleTimeout::EVENT_TYPE ].freeze
  HANDLED = [ MESSAGE_RECEIVED, Turns::Open::DISPATCH_TYPE, Turns::Open::EVENT_TYPE, Deliveries::Send::EVENT_TYPE,
              *TIMEOUTS, Handoff::Request::EVENT_TYPE,
              Deadlines::ProgressDue::EVENT_TYPE, Handoff::Summarize::EVENT_TYPE ].freeze

  def perform(outbox_event_id)
    item = OutboxEvent.find_by(id: outbox_event_id)
    return unless item && item.completed_at.nil?

    case item.event_type
    when Turns::Open::DISPATCH_TYPE
      result = Turns::Open.call(item.id)
      self.class.perform_later(result.turn.event_id) if result.status == :opened
      wake(result.handoff_event_id)
    when Turns::Open::EVENT_TYPE
      result = Outbox::Publish.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
      wake(result.handoff_event_id)
    when *TIMEOUTS
      result = Deadlines::Expire.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
      wake(result.handoff_event_id)
    when Handoff::Request::EVENT_TYPE
      Handoff::Escalate.call(item.id).wake_ids.each { wake(_1) }
    when Deliveries::Send::EVENT_TYPE
      result = Deliveries::Send.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    when Deadlines::ProgressDue::EVENT_TYPE
      result = Turns::ProgressNotice.call(item.id)
      self.class.set(wait_until: result.next_attempt_at).perform_later(item.id) if result.next_attempt_at
    when Handoff::Summarize::EVENT_TYPE
      Handoff::Summarize.call(item.id)
    when MESSAGE_RECEIVED
      Triage::OnMessage.call(item.id)
    end
  end

  private

  # Acorda o item gravado na transação do serviço, já depois do commit (invariante 2). Se o Redis falhar, o
  # item segue aberto e a recuperação o reoferece.
  def wake(outbox_event_id)
    self.class.perform_later(outbox_event_id) if outbox_event_id
  rescue StandardError => e
    JsonLog.warn("outbox.enqueue_failed", event_id: outbox_event_id, error: e.class.name)
  end
end
