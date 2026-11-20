module AgentMock
  module Scenarios
    # Decide a ação de um turno, de forma determinística (RNF-30): só depende do evento e da
    # configuração. Lê TODAS as context.pending_messages (07, seção 5.2), não só a última.
    #
    # Ordem: limite de trocas (RN-33 (6)) → primeira regra que casar → reply padrão.
    # Consulta de dados de conta exige cliente verificado (RN-05): sem verificação, pede identificação.
    class Engine
      LIMIT_RULE = "limite_de_trocas".freeze

      def initialize(config)
        @config = config
        @rules = config.rules.map { Rule.new(_1) }
      end

      def decide(event)
        return turn_limit(event) if event.dig("ticket", "ai_turns") >= @config.max_ai_turns

        text = Text.normalize(event.dig("context", "pending_messages").map { _1.fetch("text") }.join("\n"))
        rule = @rules.find { _1.match?(text) }
        return Decision.reply(rule: "padrao", text: @config.replies.fetch("default")) unless rule

        send(:"decide_#{rule.type}", rule, event, text)
      end

      private

      def decide_escalate(rule, event, _text)
        Decision.escalate(rule: rule.id, reason: rule.spec.fetch("reason"),
                          summary: summary(event, rule.spec.fetch("summary"), []))
      end

      def decide_resolve(rule, _event, _text)
        Decision.resolve(rule: rule.id, reason: rule.spec.fetch("reason"), text: rule.spec["text"])
      end

      def decide_reply(rule, _event, _text) = Decision.reply(rule: rule.id, text: rule.spec.fetch("text"))

      def decide_tool_reply(rule, event, text)
        name = rule.spec.fetch("tool")
        classification = ({ "category" => rule.category } if rule.category)
        if account_data?(name) && !event.dig("customer", "verified")
          return Decision.reply(rule: "#{rule.id}.verificacao_pendente", text: @config.replies.fetch("needs_verification"),
                                classification:)
        end

        tool = Tools.fetch(name)
        call = tool.new(seed: @config.seed).call(tool.args_for(event, text))
        Decision.reply(rule: rule.id, text: reply_text(call), tool_calls: [ call.to_h ], classification:)
      end

      def turn_limit(event)
        Decision.escalate(
          rule: LIMIT_RULE, reason: LIMIT_RULE,
          summary: summary(event, { "problema" => "Atendimento sem resolução após #{@config.max_ai_turns} trocas com a IA",
                                    "motivo" => "Limite de trocas da IA sem resolver (RN-33)",
                                    "pendente" => "Ler o histórico e resolver o problema relatado" }, [])
        )
      end

      # Os cinco campos da RN-39. dados_cliente sem PII (nada de nome, telefone ou e-mail; RN-51).
      def summary(event, spec, tool_calls)
        verified = event.dig("customer", "verified") ? "verificado" : "não verificado"
        actions = tool_calls.empty? ? "Nenhuma consulta feita pela IA neste turno" : tool_calls.map { _1["tool"] }.join(", ")
        { "problema" => spec.fetch("problema"),
          "dados_cliente" => "Cliente #{verified} (#{event.dig('customer', 'id')}), marca #{event['brand']}, canal #{event.dig('ticket', 'channel')}",
          "acoes_tomadas" => actions, "motivo" => spec.fetch("motivo"), "pendente" => spec.fetch("pendente") }
      end

      def account_data?(tool) = @config.tools.fetch(tool).fetch("account_data")

      def reply_text(call)
        templates = @config.replies.fetch(call.tool)
        template = templates.fetch(call.result["status"].to_s) { templates.fetch("default") }
        values = call.result.to_h do |key, value|
          [ key.to_sym, value.is_a?(Float) && key == "amount" ? Text.money(value) : format_value(key, value) ]
        end
        format(template, values)
      end

      def format_value(key, value)
        return Date.iso8601(value).strftime("%d/%m") if %w[date expected_at].include?(key)
        return value.to_s.tr(".", ",") if value.is_a?(Float)

        value
      end
    end
  end
end
