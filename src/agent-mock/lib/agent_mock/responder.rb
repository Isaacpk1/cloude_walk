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
  #
  # O perfil (rapido, lento, mudo) é resolvido a cada evento (Profiles): o simulador troca sem reiniciar.
  #   senão                           → decide, valida contra agent_outbound e publica
  #
  # Não há deduplicação aqui: o mesmo evento entregue de novo gera outra ação, com outro
  # event_id. A idempotência é da plataforma (processed_events e uma ação final por turno,
  # RN-47, RN-56). O agente não guarda estado.
  class Responder
    Result = Data.define(:status, :action)

    # config: perfil fixo (sem fonte de perfil). profiles: perfil por evento, escolhido pelo simulador.
    def initialize(producer:, config: nil, profiles: nil, log: Log.new, clock: SystemClock, id_generator: -> { SecureRandom.uuid })
      @publisher = Publisher.new(producer:)
      @log = log
      @profiles = profiles || Profiles.new(config: config || Config.load, log:)
      @clock = clock
      @ids = id_generator
    end

    def call(payload:, headers:)
      received_at = @clock.call
      traceparent = header(headers, "traceparent")
      violations = HelpdeskContracts.errors(:agent_inbound, payload)
      return reject_inbound(payload, headers, traceparent, violations) if violations.any?

      event = JSON.parse(payload)
      runtime = @profiles.resolve(event["brand"], trace_id: Log.trace_id(traceparent))
      context = log_context(event, traceparent, runtime)
      skipped = skip_reason(event, received_at, runtime)
      return skip(skipped, context, received_at) if skipped

      respond(event, runtime, context, traceparent, received_at)
    end

    private

    def skip_reason(event, received_at, runtime)
      return :expired if received_at >= Time.iso8601(event.fetch("deadline_at"))

      :muted if runtime.failures.mute?
    end

    def skip(status, context, received_at)
      fields = status == :expired ? { reason: "prazo_vencido", received_at: received_at.utc.iso8601(3) } : {}
      @log.info("agent.#{status}", **context, **fields)
      Result.new(status:, action: nil)
    end

    def respond(event, runtime, context, traceparent, received_at)
      latency_ms = runtime.failures.latency_ms(event.fetch("event_id"))
      @clock.sleep(latency_ms / 1000.0) if latency_ms.positive?
      if runtime.failures.fail?(event.fetch("event_id"))
        @log.warn("agent.failed", **context, reason: "falha_simulada", latency_ms:)
        return Result.new(status: :failed, action: nil)
      end

      decision = runtime.engine.decide(event)
      simulate_tools(decision)
      action = build_action(event, decision, runtime.config, received_at, @clock.call)
      violations = HelpdeskContracts.errors(:agent_outbound, action)
      return reject_action(action, context, traceparent, violations) if violations.any?

      @publisher.publish(action, traceparent:)
      @log.info("agent.published", **context, action: decision.action, rule: decision.rule, action_event_id: action["event_id"],
                                   tools: decision.tool_calls.map { _1["tool"] }, latency_ms:,
                                   agent_ms: action.dig("timing", "agent_ms"), config_hash: action.dig("agent", "config_hash"))
      Result.new(status: :published, action:)
    end

    # As consultas são sintéticas, mas o duration_ms delas é tempo de execução: o relógio avança por
    # ele, e timing.agent_ms (responded_at - received_at) cobre latência + consultas (RNF-03).
    # O duration_ms sai da semente e dos argumentos, então o agent_ms segue determinístico (RNF-30).
    def simulate_tools(decision)
      tools_ms = decision.tool_calls.sum { _1.fetch("duration_ms") }
      @clock.sleep(tools_ms / 1000.0) if tools_ms.positive?
    end

    # 07, seção 5.3: correlação igual à do evento, agent (RN-37) e timing (RNF-03).
    def build_action(event, decision, config, received_at, responded_at)
      action = {
        "schema" => "helpdesk.agent_action.v1",
        "event_id" => @ids.call,
        "in_reply_to" => event.fetch("event_id"),
        **event.slice("conversation_id", "brand", "turn", "context_until_seq", "assignment_version"),
        "action" => decision.action,
        **decision.content,
        "tool_calls" => decision.tool_calls,
        "classification" => decision.classification,
        "agent" => { "model" => MODEL, "version" => VERSION, "config_hash" => config.config_hash },
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
    def log_context(event, traceparent, runtime)
      { trace_id: Log.trace_id(traceparent), event_id: event["event_id"], conversation_id: event["conversation_id"],
        brand: event["brand"], turn: event["turn"], profile: runtime.config.profile, profile_source: runtime.source }
    end

    # Cabeçalho do Kafka pode vir como String ou, se repetido, como Array (rdkafka).
    def header(headers, name)
      value = (headers || {})[name]
      value.is_a?(Array) ? value.first : value
    end
  end
end
