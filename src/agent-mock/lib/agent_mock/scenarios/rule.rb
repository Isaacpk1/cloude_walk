module AgentMock
  module Scenarios
    # Uma regra de config/scenarios.yml: palavras-chave → tipo de resposta (ADR-008).
    #
    # Recursos opcionais, para regras que só valem com afirmação do cliente (RN-36):
    # - negations + negation_window: um termo de `any` não conta se alguma negação aparece até
    #   N palavras antes dele ("ainda nao esta resolvido", "nada foi resolvido");
    # - ignore_questions: termo dentro de uma frase ou mensagem que termina em "?" não conta ("resolveu?").
    # Tudo validado na subida (Config), e tudo entra no config_hash (RN-37).
    class Rule
      TYPES = %w[escalate resolve tool_reply reply].freeze
      # Frase: termina em . ! ? ou no fim da mensagem (o Engine junta as mensagens com "\n").
      SENTENCE = /[^.!?\n]+[.!?]*/

      attr_reader :id, :type, :spec

      def initialize(spec)
        @spec = spec
        @id = spec.fetch("id")
        @type = spec.fetch("type")
        raise Config::Invalid, "regra #{id}: tipo desconhecido #{type}" unless TYPES.include?(type)
        raise Config::Invalid, "regra #{id}: tool fora do catálogo #{spec['tool']}" if type == "tool_reply" && !Tools::CATALOG.key?(spec.fetch("tool"))

        @any = spec.fetch("any")
        @unless_any = spec.fetch("unless_any", [])
        load_negation
        @ignore_questions = spec.fetch("ignore_questions", false)
        invalid!("ignore_questions deve ser true ou false") unless [ true, false ].include?(@ignore_questions)
      end

      def match?(text) = @unless_any.none? { Text.include_term?(text, _1) } && @any.any? { affirmed?(text, _1) }
      def category = spec["category"]

      private

      def load_negation
        @negations = spec.fetch("negations", nil)
        @negation_window = spec.fetch("negation_window", nil)
        return if @negations.nil? && @negation_window.nil?

        unless @negations.is_a?(Array) && @negations.any? && @negations.all? { _1.is_a?(String) && !_1.strip.empty? }
          invalid!("negations deve ser uma lista não vazia de termos")
        end
        invalid!("negation_window deve ser inteiro >= 1") unless @negation_window.is_a?(Integer) && @negation_window >= 1
      end

      def invalid!(message) = raise(Config::Invalid, "regra #{id}: #{message}")

      # Alguma ocorrência do termo fora de pergunta (se ignore_questions) e sem negação na janela.
      def affirmed?(text, term)
        sentences(text).any? do |sentence, offset|
          Text.term_positions(sentence, term).any? { !negated?(text, offset + _1) }
        end
      end

      def sentences(text)
        found = text.to_enum(:scan, SENTENCE).map { [ Regexp.last_match[0], Regexp.last_match.begin(0) ] }
        @ignore_questions ? found.reject { |sentence, _| sentence.rstrip.end_with?("?") } : found
      end

      def negated?(text, position)
        return false unless @negations

        window = text[0...position].scan(/[[:alnum:]]+/).last(@negation_window).join(" ")
        @negations.any? { Text.include_term?(window, _1) }
      end
    end
  end
end
