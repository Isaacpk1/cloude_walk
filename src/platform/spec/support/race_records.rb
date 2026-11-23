# A corrida dos 3 s (07, seção 3.4; RN-55, RN-56) gravada pelo caminho real, para os testes do painel do
# bloco 07: Ingestion::Receive grava a mensagem 1 aos 0 s, Deadlines::DispatchDue e Turns::Open abrem o
# turno 1 aos 1,5 s, a mensagem 2 aos 3 s supera o turno 1 no commit e a resposta do turno 1 chega aos
# 3,5 s pelo AgentActions::Apply real (rejeitada como turno_superado). Com `second_turn`, o turno 2 abre
# aos 4 s (teto da janela) e a sua resposta é aplicada.
module RaceRecordsHelpers
  # A ação do agente é julgada pelo relógio do banco (DatabaseClock), que não anda com o travel_to, e a
  # auditoria usa clock_timestamp(): o cenário começa 10 s atrás, para os passos do relógio de teste
  # ficarem antes do relógio do banco e dentro do prazo do turno (RN-46).
  def race_t0 = Time.current.utc.change(usec: 0) - 10.seconds

  def record_three_second_race(brand: "infinitepay", second_turn: true, t0: race_t0)
    first = race_ingest(t0, "meu repasse não caiu", brand:)
    turn1 = race_tick(t0 + 1.5.seconds).sole.turn
    race_ingest(t0 + 3.seconds, "é o de ontem, R$ 1.200", brand:)
    rejected = race_apply(turn1, t0 + 3.5.seconds, "Qual repasse você quer consultar?")
    turn2 = second_turn ? race_tick(t0 + 4.seconds).sole.turn : nil
    applied = turn2 && race_apply(turn2, t0 + 6.seconds, "Achei o repasse de ontem, de R$ 1.200.")
    { t0:, ticket: first.ticket.reload, turn1: turn1.reload, turn2: turn2&.reload, rejected:, applied: }
  end

  private

  def race_ingest(at, text, brand:)
    travel_to(at, with_usec: true) { ingest(text, brand:) }
  end

  def race_tick(at)
    travel_to(at, with_usec: true) do
      Deadlines::DispatchDue.call(now: Time.current, limit: 100).map { Turns::Open.call(_1) }
    end
  end

  def race_apply(turn, at, text)
    travel_to(at, with_usec: true) do
      AgentActions::Apply.call(agent_action_for(turn, reply: { "text" => text }), traceparent: AgentActionHelpers::TRACEPARENT)
    end
  end
end

RSpec.configure { |c| c.include RaceRecordsHelpers }
