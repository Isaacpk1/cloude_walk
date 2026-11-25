# Publicação de um evento do outbox no broker (07, seções 3.1 e 6; ADR-006, ADR-007).
#
#   Outbox::Publish.call(outbox_event_id) # => Result(status:, next_attempt_at:, handoff_event_id:)
#
# 1. Reserva o item (lease) com uma atualização condicional: dois workers não chamam o broker juntos.
# 2. Atendimento de eval (ADR-023, item 5) não sai: o item encerra como descarte `eval`.
#    Revalida o turno: superado, vencido ou de outra atribuição não sai (07, seção 6, backlog).
# 3. Valida o contrato na saída (invariante 10).
# 4. Chama o broker FORA de qualquer transação (invariante 2), com o mesmo corpo e o mesmo event_id
#    em todas as tentativas (invariante 3).
# 5. Grava o resultado e a auditoria numa transação curta.
#
# Retentativas (RN-43, RNF-16; Outbox::RetryPolicy): 5xx, 429, timeout e conexão recusada esperam 1, 2, 4,
# 8 e 16 s, mais um jitter de até 25%, enquanto o prazo do turno permitir (07, seção 6). 4xx é permanente
# (RN-44). Uma tentativa abandonada (worker caiu depois da reserva) conta: a reserva além do limite não
# chama o broker e encerra como retentativas_esgotadas (origem recuperacao).
# Falha definitiva (recusa do broker, contrato inválido, retentativas esgotadas ou sem tempo no prazo do turno)
# escala na hora (RN-46, ADR-020 item 3): com o atendimento travado, se o turno ainda é `eligible`, da atribuição
# atual e o caso está com a IA, grava `handoff.requested` (`publicacao_falhou`, origem `outbox`) na mesma
# transação do desfecho. O OutboxJob acorda o handoff pelo `handoff_event_id`, depois do commit.
module Outbox
  class Publish
    Result = Data.define(:status, :next_attempt_at, :handoff_event_id) do
      def initialize(handoff_event_id: nil, **) = super
    end
    HANDOFF_REASON = "publicacao_falhou".freeze

    # Reserva de uma tentativa: cobre a chamada inteira (BrokerClient: 2 s para abrir + 10 s de leitura) com folga
    # e vence antes do prazo do turno (20 s, ADR-020), para a recuperação ainda retomar a publicação de um worker
    # que caiu no meio da chamada (RNF-17).
    LEASE = 15.seconds
    MAX_RETRIES = RetryPolicy::MAX_RETRIES
    DEFAULT_JITTER = RetryPolicy::DEFAULT_JITTER
    EVAL_REASON = "eval".freeze

    def self.call(...) = new(...).call

    def initialize(outbox_event_id, client: BrokerClient.new, jitter: DEFAULT_JITTER)
      @id = outbox_event_id
      @client = client
      @jitter = jitter
    end

    def call
      case admission_claim
      when :waiting then return wait_for_slot
      when false then return not_claimed
      end

      @item = OutboxEvent.find(@id)
      @turn = AiTurn.find_by(event_id: @item.id)
      # ADR-023, item 5: o turno de um atendimento de eval não sai para o broker; o gabarito responde por ele.
      return discard(EVAL_REASON) if evaluation?

      stale = stale_reason
      return discard(stale) if stale
      return abandoned_exhausted if RetryPolicy.exceeded?(item.attempts)

      violations = HelpdeskContracts.errors(:agent_inbound, @item.payload)
      return reject(origin: "plataforma", http_status: nil, reason: "contrato", violations: violations.map(&:pointer)) if violations.any?

      deliver
    end

    private

    attr_reader :item, :turn

    def claim
      now = Time.current
      OutboxEvent.where(id: @id, completed_at: nil).where(next_attempt_at: ..now)
                 .where("lease_until IS NULL OR lease_until < ?", now)
                 .update_all([ "lease_until = ?, attempts = attempts + 1", now + LEASE ]) == 1
    end

    # ADR-035: com o controle de admissão ligado, a reserva só acontece se o agente tiver vaga para este turno.
    def admission_claim
      return claim unless Admission.enabled?

      ActiveRecord::Base.transaction do
        Admission.serialize!
        now = Time.current
        row = OutboxEvent.find_by(id: @id)
        next claim unless row && row.event_type == Admission::EVENT_TYPE && row.completed_at.nil? && row.next_attempt_at <= now

        waiting_turn = AiTurn.find_by(event_id: row.id)
        next claim if waiting_turn.nil? || !waiting_turn.eligible?

        Admission.admit?(row, waiting_turn, now:) ? claim : :waiting
      end
    end

    # Sem vaga. Obsoleto sai sem ocupar o agente; sem tempo para a resposta caber no prazo, o caso vai para um humano
    # agora (RN-46); senão espera, sem gastar tentativa, e o aviso ao cliente sai cedo (RN-57).
    def wait_for_slot
      @item = OutboxEvent.find(@id)
      @turn = AiTurn.find_by(event_id: @item.id)
      stale = stale_reason
      return discard(stale) if stale

      now = Time.current
      if turn.deadline_at - now < Admission.expected_agent_time
        @handoff_reason = Admission::HANDOFF_REASON
        return terminal(Admission::HANDOFF_REASON, { origin: "admissao", http_status: nil,
                                                     error: "agente sem vaga a tempo do prazo do turno", retry: false })
      end

      Admission.bring_notice_forward(turn, now:)
      retry_at = now + Admission::POLL
      OutboxEvent.where(id: @id, completed_at: nil).update_all(next_attempt_at: retry_at)
      Result.new(status: :waiting_slot, next_attempt_at: retry_at)
    end

    def not_claimed
      current = OutboxEvent.find_by(id: @id)
      due = current && current.completed_at.nil? && current.next_attempt_at > Time.current
      Result.new(status: due ? :not_due : :skipped, next_attempt_at: due ? current.next_attempt_at : nil)
    end

    def evaluation? = Ticket.where(id: item.ticket_id, brand_id: item.brand_id).pick(:evaluation) == true

    # Turno superado, vencido, de outra atribuição ou de caso que saiu da IA (Outbox::Obsolescence).
    def stale_reason
      return unless turn

      Obsolescence.turn_reason(turn, Ticket.find_by(id: turn.ticket_id, brand_id: item.brand_id), now: Time.current)
    end

    # As tentativas anteriores foram abandonadas (sem resultado gravado) até passar do limite da RN-43.
    def abandoned_exhausted
      terminal("retentativas_esgotadas", { origin: "recuperacao", http_status: nil, error: "tentativas abandonadas",
                                           retry: false })
    end

    def deliver
      started = Time.current
      response = @client.deliver(body: JSON.generate(item.payload), event_id: item.id, traceparent:)
      classify(response, duration_ms: ((Time.current - started) * 1000).round)
    rescue BrokerClient::Unreachable => e
      transient(origin: "broker_indisponivel", http_status: nil, error: e.message)
    end

    def classify(response, duration_ms:)
      body = response.body
      case response.status
      when 200..299 then published(body, duration_ms:)
      when 401, 403 then reject(origin: "assinatura", http_status: response.status, reason: body["reason"])
      when 422 then reject(origin: "contrato", http_status: 422, reason: body["reason"],
                           violations: Array(body["violations"]).filter_map { _1["pointer"] if _1.is_a?(Hash) })
      when 429 then transient(origin: "broker", http_status: 429, error: "limite de requisições do broker")
      when 400..499 then reject(origin: "broker", http_status: response.status, reason: body["status"])
      else transient(**server_error(response))
      end
    end

    def server_error(response)
      case response.body["status"]
      when "unavailable" then { origin: "kafka", http_status: response.status, error: "Kafka sem confirmação (via broker)" }
      when "in_flight" then { origin: "broker_em_andamento", http_status: response.status, error: "outra entrega do mesmo evento em andamento" }
      else { origin: "broker", http_status: response.status, error: "erro #{response.status} do broker" }
      end
    end

    def published(body, duration_ms:)
      now = Time.current
      finish(published_at: now, completed_at: now, last_error: nil) do
        audit("agent_event.published", broker_status: body["status"], topic: body["topic"], partition: body["partition"],
                                       offset: body["offset"], duration_ms:)
      end
      JsonLog.info("outbox.published", trace_id: item.trace_id, event_id: item.id, ticket_id: item.ticket_id,
                                       turn: turn&.turn, attempt: item.attempts, partition: body["partition"], offset: body["offset"])
      Result.new(status: :published, next_attempt_at: nil)
    end

    def transient(origin:, http_status:, error:)
      retry_at = Time.current + backoff
      outcome = if item.attempts > MAX_RETRIES then "retentativas_esgotadas"
      elsif turn && retry_at >= turn.deadline_at then "prazo_vencido"
      end
      data = { origin:, http_status:, error:, retry: outcome.nil? }
      return terminal(outcome, data) if outcome

      finish(next_attempt_at: retry_at, last_error: error) do
        audit("agent_event.publish_failed", **data, next_attempt_at: retry_at.utc.iso8601(3))
      end
      JsonLog.warn("outbox.publish_failed", trace_id: item.trace_id, event_id: item.id, attempt: item.attempts, origin:,
                                            http_status:, outcome:)
      Result.new(status: :retry_scheduled, next_attempt_at: retry_at)
    end

    # Sem nova tentativa. O evento pode ter chegado ao Kafka e o agente, respondido antes de a resposta HTTP se
    # perder (07, seção 6: o ACK posterior atualiza só a publicação). Com a linha do atendimento travada (a mesma
    # ordem do resto do sistema: atendimento, depois o item), o turno é relido: se deixou de ser elegível, não há
    # falha definitiva de publicação a registrar e o item encerra como descarte; senão, publish_failed terminal.
    def terminal(outcome, data)
      stale = nil
      finish(lock_ticket: true, completed_at: Time.current, last_error: data[:error]) do |ticket|
        stale = turn && !turn.reload.eligible? && "turno_#{turn.status}"
        next audit("agent_event.discarded", reason: stale) if stale

        audit("agent_event.publish_failed", **data, outcome:)
        request_handoff(ticket)
      end
      return discarded(stale) if stale

      JsonLog.warn("outbox.publish_failed", trace_id: item.trace_id, event_id: item.id, attempt: item.attempts,
                                            origin: data[:origin], http_status: data[:http_status], outcome:)
      Result.new(status: outcome == "retentativas_esgotadas" ? :exhausted : :expired, next_attempt_at: nil,
                 handoff_event_id: @handoff_event_id)
    end

    # 1, 2, 4, 8, 16 s pela tentativa que falhou, mais até 25% de jitter (só para cima).
    def backoff = RetryPolicy.backoff(item.attempts, jitter: @jitter)

    def reject(origin:, http_status:, reason:, violations: nil)
      error = "#{origin}: #{reason}"
      finish(lock_ticket: true, completed_at: Time.current, last_error: error) do |ticket|
        audit("agent_event.rejected", **{ origin:, http_status:, reason:, violations: }.compact)
        request_handoff(ticket)
      end
      JsonLog.warn("outbox.rejected", trace_id: item.trace_id, event_id: item.id, origin:, http_status:, reason:)
      Result.new(status: :rejected, next_attempt_at: nil, handoff_event_id: @handoff_event_id)
    end

    def discard(reason)
      finish(completed_at: Time.current) { audit("agent_event.discarded", reason:) }
      discarded(reason)
    end

    def discarded(reason)
      JsonLog.info("outbox.discarded", trace_id: item.trace_id, event_id: item.id, reason:)
      Result.new(status: :discarded, next_attempt_at: nil)
    end

    # Grava o desfecho só se o item ainda for desta tentativa (aberto), na mesma transação da auditoria. Com
    # `lock_ticket`, trava antes a linha do atendimento (da marca do item), na ordem atendimento → item.
    def finish(lock_ticket: false, **attrs)
      ActiveRecord::Base.transaction do
        ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: item.ticket_id, brand_id: item.brand_id) if lock_ticket
        updated = OutboxEvent.where(id: item.id, completed_at: nil).update_all(attrs.merge(lease_until: nil))
        yield ticket if updated == 1
      end
    end

    # RN-46: só com o atendimento travado (por `finish(lock_ticket: true)`) e para o turno que ainda vale.
    def request_handoff(ticket)
      return unless ticket && turn
      return unless turn.reload.eligible? && turn.assignment_version == ticket.assignment_version && ticket.with_ai?

      @handoff_event_id = Handoff::Request.call(ticket:, reason: @handoff_reason || HANDOFF_REASON, source: "outbox", turn: turn.turn,
                                                trace_id: item.trace_id)
    end

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: item.ticket_id, actor_type: "system", event_type:,
                         trace_id: item.trace_id, data: { event_id: item.id, turn: turn&.turn, attempt: item.attempts }.merge(data))
    end

    # W3C Trace Context (RF-56). O span é derivado do event_id: igual em todas as tentativas.
    def traceparent
      trace = item.trace_id.to_s.match?(/\A\h{32}\z/) ? item.trace_id : item.id.delete("-")
      "00-#{trace.downcase}-#{item.id.delete('-')[0, 16]}-01"
    end
  end
end
