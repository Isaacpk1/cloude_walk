require "json"

module AgentMock
  module Scenarios
    # Motor híbrido (ADR-030): a política fica nas regras e o modelo só redige a resposta.
    #
    #   escalate, resolve, limite de trocas, cliente não verificado → decisão das regras, sem chamar o modelo
    #   reply (consulta sintética ou caso padrão)                   → o Gemini redige a partir dos dados consultados
    #   falha, timeout, teto de chamadas ou saída inválida          → a resposta das regras (degradação, nunca silêncio)
    #
    # Só o texto das mensagens, a marca, o canal, se o cliente é verificado e o resultado das consultas sintéticas vão
    # ao modelo. Nada de nome, telefone, e-mail ou ID do cliente (RN-51). Use só dados sintéticos (ADR-030).
    class GeminiEngine
      SCHEMA = { type: "OBJECT", properties: { text: { type: "STRING" } }, required: [ "text" ] }.freeze
      MAX_TEXT = 1000
      FALLBACK_ERRORS = [ GeminiClient::Error, JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
                          SystemCallError, OpenSSL::SSL::SSLError ].freeze

      # Teto de chamadas e de simultaneidade, para custo e limite de uso do provedor.
      class Budget
        def initialize(max_calls:, max_concurrency:)
          @lock = Mutex.new
          @calls = 0
          @max_calls = max_calls
          @slots = Thread::SizedQueue.new(max_concurrency)
          max_concurrency.times { @slots << true }
        end

        def acquire
          return false if @lock.synchronize { (@calls += 1) > @max_calls }

          @slots.pop
          true
        end

        def release = @slots << true
      end

      def self.shared_budget(limits) = (@shared_budget ||= Budget.new(max_calls: limits.fetch(:max_calls), max_concurrency: limits.fetch(:max_concurrency)))

      def initialize(config, client: nil, budget: nil, log: Log.new, rules: Engine.new(config))
        @config = config
        @rules = rules
        @log = log
        @client = client || GeminiClient.new(timeout_s: config.llm_limits.fetch(:timeout_s))
        @budget = budget || self.class.shared_budget(config.llm_limits)
      end

      def decide(event)
        base = @rules.decide(event)
        return base unless llm_eligible?(base)

        text = ask(event, base)
        return base unless text

        Decision.reply(rule: "#{base.rule}.gemini", text:, tool_calls: base.tool_calls, classification: base.classification)
      end

      private

      def llm_eligible?(decision)
        decision.action == "reply" && !decision.rule.end_with?(".verificacao_pendente")
      end

      def ask(event, base)
        return fallback(event, "teto_de_chamadas") unless @budget.acquire

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raw = @client.generate(model: @config.llm.fetch("model"), system: @config.llm.fetch("system_prompt"), prompt: prompt(event, base),
                               schema: SCHEMA, temperature: @config.llm.fetch("temperature"),
                               max_output_tokens: @config.llm.fetch("max_output_tokens"))
        text = clean(JSON.parse(raw)["text"])
        return fallback(event, "saida_invalida") unless text

        @log.info("agent.llm_ok", event_id: event["event_id"], conversation_id: event["conversation_id"], model: @config.llm.fetch("model"),
                                  llm_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        text
      rescue *FALLBACK_ERRORS => e
        fallback(event, e.is_a?(GeminiClient::Error) ? e.message : e.class.name)
      ensure
        @budget.release if started
      end

      def fallback(event, reason)
        @log.warn("agent.llm_fallback", event_id: event["event_id"], conversation_id: event["conversation_id"], reason:)
        nil
      end

      def clean(text)
        return unless text.is_a?(String)

        text = text.gsub(/[[:cntrl:]&&[^\n]]/, "").strip[0, MAX_TEXT]
        text unless text.empty?
      end

      def prompt(event, base)
        JSON.generate(
          "marca" => event["brand"], "canal" => event.dig("ticket", "channel"),
          "cliente_verificado" => event.dig("customer", "verified") ? true : false,
          "mensagens_do_cliente" => event.dig("context", "pending_messages").map { _1.fetch("text") },
          "dados_consultados" => base.tool_calls.map { { "ferramenta" => _1["tool"], "resultado" => _1["result"] } },
          "resposta_base" => base.content.dig("reply", "text")
        )
      end
    end

    def self.build_engine(config) = config.engine == "gemini" ? GeminiEngine.new(config) : Engine.new(config)
  end
end
