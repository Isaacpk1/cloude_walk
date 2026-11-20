require "json"
require "securerandom"
require "time"

module AgentMock
  # Um evento de helpdesk.agent.inbound.v1 → no máximo uma ação em helpdesk.agent.outbound.v1
  # (ADR-008; 07, seção 3.1, passo 5).
  #
  #   contrato agent_inbound inválido → DLQ, sem retentativa (invariante 10)
  #   deadline_at já passou           → descarta e loga (07, seção 6, "Agente lento ou fora do ar")
  #   modo mudo / falha sorteada      → nada sai (RF-38)
  #   senão                           → decide, valida contra agent_outbound e publica
  #
  # Não há deduplicação aqui: o mesmo evento entregue de novo gera outra ação, com outro
  # event_id. A idempotência é da plataforma (processed_events e uma ação final por turno,
  # RN-47, RN-56). O agente não guarda estado.
  class Responder
    Result = Data.define(:status, :action)

    def initialize(producer:, config: Config.load, log: Log.new, clock: SystemClock, id_generator: -> { SecureRandom.uuid })
      @publisher = Publisher.new(producer:)
      @config = config
      @log = log
      @clock = clock
      @ids = id_generator
      @failures = FailureModes.new(config)
      @engine = Scenarios::Engine.new(config)
    end

    def call(payload:, headers:)
      received_at = @clock.call
      traceparent = header(headers, "traceparent")
      violations = HelpdeskContracts.errors(:agent_inbound, payload)
      return reject_inbound(payload, headers, traceparent, violations) if violations.any?

      event = JSON.parse(payload)
      context = log_context(event, traceparent)
      skipped = skip_reason(event, received_at)
      return skip(skipped, context, received_at) if skipped

      respond(event, context, traceparent, received_at)
    end

    private

    def skip_reason(event, received_at)
      return :expired if received_at >= Time.iso8601(event.fetch("deadline_at"))

      :muted if @failures.mute?
    end

    def skip(status, context, received_at)
      fields = status == :expired ? { reason: "prazo_vencido", received_at: received_at.utc.iso8601(3) } : {}
      @log.info("agent.#{status}", **context, **fields)
      Result.new(status:, action: nil)
    end

    def respond(event, context, traceparent, received_at)
      latency_ms = @failures.latency_ms(event.fetch("event_id"))
      @clock.sleep(latency_ms / 1000.0) if latency_ms.positive?
      if @failures.fail?(event.fetch("event_id"))
        @log.warn("agent.failed", **context, reason: "falha_simulada", latency_ms:)
        return Result.new(status: :failed, action: nil)
      end

      decision = @engine.decide(event)
      action = build_action(event, decision, received_at, @clock.call)
      violations = HelpdeskContracts.errors(:agent_outbound, action)
      return reject_action(action, context, traceparent, violations) if violations.any?

      @publisher.publish(action, traceparent:)
      @log.info("agent.published", **context, action: decision.action, rule: decision.rule, action_event_id: action["event_id"],
                                   tools: decision.tool_calls.map { _1["tool"] }, latency_ms:,
                                   agent_ms: action.dig("timing", "agent_ms"))
      Result.new(status: :published, action:)
    end

    # 07, seção 5.3: correlação igual à do evento, agent (RN-37) e timing (RNF-03).
    def build_action(event, decision, received_at, responded_at)
      action = {
        "schema" => "helpdesk.agent_action.v1",
        "event_id" => @ids.call,
        "in_reply_to" => event.fetch("event_id"),
        **event.slice("conversation_id", "brand", "turn", "context_until_seq", "assignment_version"),
        "action" => decision.action,
        **decision.content,
        "tool_calls" => decision.tool_calls,
        "classification" => decision.classification,
        "agent" => { "model" => MODEL, "version" => VERSION, "config_hash" => @config.config_hash },
        "timing" => { "received_at" => received_at.utc.iso8601(3), "responded_at" => responded_at.utc.iso8601(3),
                      "agent_ms" => ((responded_at - received_at) * 1000).round }
      }
      action.compact
    end

    def reject_inbound(payload, headers, traceparent, violations)
      event_id = header(headers, "event_id")
      @publisher.dead_letter(body: payload, key: conversation_key(payload) || event_id, reason: "contrato",
                             violations: violations.map(&:to_h), event_id:, traceparent:)
      @log.warn("agent.dead_lettered", trace_id: Log.trace_id(traceparent), event_id:, reason: "contrato",
                                       violations: violations.map(&:pointer))
      Result.new(status: :dead_lettered, action: nil)
    end

    # Ação fora do contrato é defeito do agente: não publica em outbound, manda para a DLQ.
    def reject_action(action, context, traceparent, violations)
      @log.error("agent.invalid_action", **context, reason: "acao_invalida", violations: violations.map(&:pointer))
      @publisher.dead_letter(body: JSON.generate(action), key: action["conversation_id"], reason: "acao_invalida",
                             violations: violations.map(&:to_h), event_id: action["event_id"], traceparent:)
      Result.new(status: :dead_lettered, action: nil)
    end

    def conversation_key(payload)
      parsed = JSON.parse(payload)
      parsed["conversation_id"] if parsed.is_a?(Hash) && parsed["conversation_id"].is_a?(String)
    rescue JSON::ParserError
      nil
    end

    # Sem texto do cliente nem display_name no log (RN-51).
    def log_context(event, traceparent)
      { trace_id: Log.trace_id(traceparent), event_id: event["event_id"], conversation_id: event["conversation_id"],
        brand: event["brand"], turn: event["turn"] }
    end

    # Cabeçalho do Kafka pode vir como String ou, se repetido, como Array (rdkafka).
    def header(headers, name)
      value = (headers || {})[name]
      value.is_a?(Array) ? value.first : value
    end
  end
end
