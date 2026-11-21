# Publicação de um evento do outbox no broker (07, seções 3.1 e 6; ADR-006, ADR-007).
#
#   Outbox::Publish.call(outbox_event_id) # => Result(status:, next_attempt_at:)
#
# 1. Reserva o item (lease) com uma atualização condicional: dois workers não chamam o broker juntos.
# 2. Revalida o turno: superado, vencido ou de outra atribuição não sai (07, seção 6, backlog).
# 3. Valida o contrato na saída (invariante 10).
# 4. Chama o broker FORA de qualquer transação (invariante 2), com o mesmo corpo e o mesmo event_id
#    em todas as tentativas (invariante 3).
# 5. Grava o resultado e a auditoria numa transação curta.
#
# Retentativas (RN-43, RNF-16): 5xx, 429, timeout e conexão recusada esperam 1, 2, 4, 8 e 16 s, mais
# um jitter de até 25%, enquanto o prazo do turno permitir (07, seção 6). 4xx é permanente (RN-44).
# A DLQ da plataforma e a escalação pela RN-45 entram no bloco 09; o timeout do ciclo, no bloco 08.
module Outbox
  class Publish
    Result = Data.define(:status, :next_attempt_at)

    LEASE = 30.seconds
    MAX_RETRIES = 5
    MAX_JITTER = 0.25
    DEFAULT_JITTER = -> { rand }

    def self.call(...) = new(...).call

    def initialize(outbox_event_id, client: BrokerClient.new, jitter: DEFAULT_JITTER)
      @id = outbox_event_id
      @client = client
      @jitter = jitter
    end

    def call
      return not_claimed unless claim

      @item = OutboxEvent.find(@id)
      @turn = AiTurn.find_by(event_id: @item.id)
      stale = stale_reason
      return discard(stale) if stale

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

    def not_claimed
      current = OutboxEvent.find_by(id: @id)
      due = current && current.completed_at.nil? && current.next_attempt_at > Time.current
      Result.new(status: due ? :not_due : :skipped, next_attempt_at: due ? current.next_attempt_at : nil)
    end

    def stale_reason
      return unless turn
      return "turno_#{turn.status}" unless turn.eligible?
      return "prazo_vencido" if Time.current >= turn.deadline_at

      "atribuicao_mudou" if Ticket.where(id: turn.ticket_id).pick(:assignment_version) != turn.assignment_version
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
      # O evento pode ter chegado ao Kafka e o agente, respondido antes de a resposta HTTP se perder (07, seção
      # 6: o ACK posterior atualiza só a publicação). Um turno que deixou de ser elegível não tem falha definitiva
      # de publicação a registrar: o item encerra como descarte, como na revalidação antes de publicar.
      stale = outcome && turn && !turn.reload.eligible? && "turno_#{turn.status}"
      return discard(stale) if stale

      data = { origin:, http_status:, error:, retry: outcome.nil? }

      if outcome
        finish(completed_at: Time.current, last_error: error) { audit("agent_event.publish_failed", **data, outcome:) }
      else
        finish(next_attempt_at: retry_at, last_error: error) do
          audit("agent_event.publish_failed", **data, next_attempt_at: retry_at.utc.iso8601(3))
        end
      end
      JsonLog.warn("outbox.publish_failed", trace_id: item.trace_id, event_id: item.id, attempt: item.attempts, origin:,
                                            http_status:, outcome:)
      status = { nil => :retry_scheduled, "retentativas_esgotadas" => :exhausted, "prazo_vencido" => :expired }.fetch(outcome)
      Result.new(status:, next_attempt_at: outcome ? nil : retry_at)
    end

    # 1, 2, 4, 8, 16 s pela tentativa que falhou, mais até 25% de jitter (só para cima).
    def backoff
      base = 2**(item.attempts - 1)
      (base * (1 + (MAX_JITTER * @jitter.call))).seconds
    end

    def reject(origin:, http_status:, reason:, violations: nil)
      error = "#{origin}: #{reason}"
      finish(completed_at: Time.current, last_error: error) do
        audit("agent_event.rejected", **{ origin:, http_status:, reason:, violations: }.compact)
      end
      JsonLog.warn("outbox.rejected", trace_id: item.trace_id, event_id: item.id, origin:, http_status:, reason:)
      Result.new(status: :rejected, next_attempt_at: nil)
    end

    def discard(reason)
      finish(completed_at: Time.current) { audit("agent_event.discarded", reason:) }
      JsonLog.info("outbox.discarded", trace_id: item.trace_id, event_id: item.id, reason:)
      Result.new(status: :discarded, next_attempt_at: nil)
    end

    # Grava o desfecho só se o item ainda for desta tentativa (aberto), na mesma transação da auditoria.
    def finish(**attrs)
      ActiveRecord::Base.transaction do
        updated = OutboxEvent.where(id: item.id, completed_at: nil).update_all(attrs.merge(lease_until: nil))
        yield if updated == 1
      end
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
