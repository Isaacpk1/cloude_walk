# Linha do tempo da corrida dos turnos com as peças reais (07, seção 3.4, diagrama; RN-55, RN-56):
# a ingestão grava a mensagem, o scheduler (Deadlines::DispatchDue) registra a abertura, o worker abre o
# turno (Turns::Open) e publica o evento no broker simulado (Outbox::Publish, spec/support/broker.rb), e o
# consumer aplica a ação do agente (AgentActions::Apply). O relógio anda com travel_to(with_usec: true).
#
# A ação do agente é julgada pelo relógio do banco (DatabaseClock), que não acompanha o travel_to: quem usa
# estes helpers começa o cenário em `Time.current`, para os prazos (20 s do turno, 60 s do ciclo) valerem.
module RaceTimelineHelpers
  def race_ingest_at(at, text, identity: "acc_infinitepay_corrida")
    travel_to(at, with_usec: true) { ingest(text, identity:) }
  end

  # Uma volta do scheduler no instante `at` e o worker abrindo e publicando os turnos registrados.
  def race_tick_at(at)
    travel_to(at, with_usec: true) do
      Deadlines::DispatchDue.call(now: Time.current, limit: 100).filter_map do |id|
        turn = Turns::Open.call(id).turn
        Outbox::Publish.call(turn.event_id) if turn
        turn
      end
    end
  end

  def race_apply_at(at, action)
    travel_to(at, with_usec: true) { AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT) }
  end

  def race_reply(turn, text) = agent_action_for(turn, reply: { "text" => text })

  def pending_seqs_of(turn) = turn.context.fetch("pending_messages").map { _1["seq"] }

  def outbound_messages(ticket) = Message.where(ticket_id: ticket.id, brand_id: ticket.brand_id, direction: "outbound")
end

RSpec.configure { |c| c.include RaceTimelineHelpers }
