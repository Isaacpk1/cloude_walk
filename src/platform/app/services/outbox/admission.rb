# Controle de admissão do agente (ADR-035). A plataforma é dona da fila: o evento do turno (agent.event) só é publicado
# quando o agente tem vaga, e a espera acontece aqui, no Postgres, onde dá para priorizar, avisar e desistir a tempo.
# O tópico do Kafka vira um buffer do tamanho da capacidade do agente.
#
#   Outbox::Admission.limit            # => AGENT_MAX_IN_FLIGHT (nil: desligado, a publicação segue como antes)
#   Outbox::Admission.admit?(item, turn, now:)
#
# Vaga ocupada = turno publicado e ainda sem resposta dentro do prazo, mais os que estão sendo publicados agora (com
# reserva). A decisão roda com uma trava consultiva da transação, para dois workers não ocuparem a mesma vaga. A ordem
# é prazo mais próximo primeiro (deadline_at, depois id): quem tem vaga é quem está na frente da fila.
module Outbox
  module Admission
    module_function

    EVENT_TYPE = "agent.event".freeze
    # Chave da trava consultiva (pg_advisory_xact_lock): uma fila de admissão para o agente inteiro.
    LOCK_KEY = 35_035_035
    # Intervalo entre as conferências de vaga de um turno na espera.
    POLL = 1.second
    # Na espera há esse tempo: o aviso de progresso ao cliente (RN-57) sai agora, não aos 15 s.
    NOTICE_AFTER = 5.seconds
    HANDOFF_REASON = "agente_sem_vaga".freeze

    def limit
      value = ENV["AGENT_MAX_IN_FLIGHT"].to_i
      value.positive? ? value : nil
    end

    def enabled? = !limit.nil?

    # Tempo que o agente leva para responder (p95 combinado no contrato; com o mock realista, até 12 s). Se o que sobra
    # do prazo do turno é menos que isso, publicar só ocupa o agente com uma resposta que vai chegar tarde.
    def expected_agent_time = (ENV.fetch("AGENT_EXPECTED_MS", "12000").to_i / 1000.0).seconds

    def serialize! = ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")

    def admit?(item, turn, now:)
      in_flight(now) + ahead_of(item, turn, now) < limit
    end

    def in_flight(now)
      answered_pending = AiTurn.joins("JOIN outbox_events o ON o.id = ai_turns.event_id")
                               .where(status: "eligible", response_received_at: nil)
                               .where("o.published_at IS NOT NULL").where("ai_turns.deadline_at > ?", now).count
      publishing = OutboxEvent.where(event_type: EVENT_TYPE, completed_at: nil, published_at: nil)
                              .where("lease_until > ?", now).count
      answered_pending + publishing
    end

    def ahead_of(item, turn, now)
      OutboxEvent.joins("JOIN ai_turns t ON t.event_id = outbox_events.id")
                 .where(event_type: EVENT_TYPE, completed_at: nil, published_at: nil)
                 .where("outbox_events.lease_until IS NULL OR outbox_events.lease_until <= ?", now)
                 .where("t.status = 'eligible' AND t.deadline_at > ?", now)
                 .where.not(id: item.id)
                 .where("(t.deadline_at, t.id) < (?, ?)", turn.deadline_at, turn.id).count
    end

    # Adianta o aviso de progresso do ciclo (RN-57) quando o turno já espera vaga há NOTICE_AFTER. Só antecipa: se o
    # aviso já saiu (progress_due_at nulo) ou já venceu, nada muda.
    def bring_notice_forward(turn, now:)
      return if now - turn.created_at < NOTICE_AFTER

      Ticket.where(id: turn.ticket_id, brand_id: turn.brand_id).where("progress_due_at > ?", now)
            .update_all(progress_due_at: now)
    end
  end
end
