module AgentMock
  module Scenarios
    # O que o agente decidiu para um turno: a ação (catálogo fechado da RN-35), o conteúdo dela,
    # as consultas feitas e a regra que casou (só para log e teste, não vai no contrato).
    Decision = Data.define(:action, :rule, :content, :tool_calls, :classification) do
      def self.reply(rule:, text:, tool_calls: [], classification: nil)
        new(action: "reply", rule:, content: { "reply" => { "text" => text } }, tool_calls:, classification:)
      end

      def self.escalate(rule:, reason:, summary:, tool_calls: [], classification: nil)
        new(action: "escalate", rule:, content: { "escalation" => { "reason" => reason, "summary" => summary } },
            tool_calls:, classification:)
      end

      def self.resolve(rule:, reason:, text: nil)
        resolution = { "reason" => reason, "text" => text }.compact
        new(action: "resolve", rule:, content: { "resolution" => resolution }, tool_calls: [], classification: nil)
      end
    end
  end
end
