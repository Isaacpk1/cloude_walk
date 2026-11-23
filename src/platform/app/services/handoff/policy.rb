# Parâmetros do handoff num lugar só (07, seção 3.2; 06, parâmetros).
#
#   policy = Handoff::Policy.for(brand)
#   policy.transfer_notice_text(brand.locale)          # aviso de transferência (RN-42)
#   policy.human_request?(text, brand.locale)          # pedido explícito de humano (RN-34)
#   policy.raise_priority?(reason)                     # RN-41: tempo ou falha de integração sobem um nível
#   policy.raised_priority(ticket.priority)
#   policy.exchanges_limit                             # RN-33, item 6: trocas da IA sem resolver antes de escalar
#
# Hoje toda marca usa os padrões. No bloco 12, `for` passa a ler a configuração versionada da marca (textos e
# expressões por marca e idioma, RN-34 e RN-42); quem chama não muda.
module Handoff
  Policy = Data.define(:transfer_notice_texts, :human_request_patterns, :priority_raising_reasons, :exchanges_limit) do
    # Idioma sem texto é erro, como no aviso de progresso: um padrão esconderia uma marca nova sem o aviso.
    def transfer_notice_text(locale) = transfer_notice_texts.fetch(locale)

    # RN-34: o pedido é o cliente pedir um humano, não a menção a uma pessoa nem a vontade de conversar. Compara sem
    # acento e sem diferenciar maiúsculas, trecho a trecho (vírgula, ponto, dois pontos...): um trecho negado ("não
    # quero falar com atendente") não conta, e outro trecho da mesma mensagem pode pedir ("não caiu, quero um atendente").
    def human_request?(text, locale)
      return false if text.blank?

      patterns = human_request_patterns.fetch(locale, nil) or return false
      clauses(text).any? { |clause| clause.match?(patterns[:ask]) && !clause.match?(patterns[:negation]) }
    end

    def clauses(text)
      I18n.transliterate(text.to_s).downcase.split(/[,.;:!?\n]+/).map(&:squish).reject(&:empty?)
    end

    def raise_priority?(reason) = priority_raising_reasons.include?(reason)

    # RN-12: crítica > alta > média > baixa. RN-14: a automática só sobe. Sem prioridade (sem triagem ainda,
    # bloco 11), vale a média da RN-13.
    def raised_priority(priority)
      levels = Handoff::Policy::PRIORITIES
      index = levels.index(priority || "media") || levels.index("media")
      levels[[ index - 1, 0 ].max]
    end
  end

  class Policy
    PRIORITIES = %w[critica alta media baixa].freeze

    HUMAN_PT = "(atendente|humano|pessoa|especialista|alguem de verdade)".freeze
    PT_BR = {
      ask: Regexp.union(
        /\b(quero|queria|preciso|posso|gostaria de|me (passa|transfere|coloca))\b.*\b#{HUMAN_PT}\b/,
        /\bfalar com (um |uma |algum |alguma |o |a )?(atendente|humano|pessoa|alguem|especialista)\b/,
        /\batendimento humano\b/,
        /\b(um|uma) (atendente|pessoa) de verdade\b/,
        /\A(um |uma |o |a )?(atendente|humano)( por favor| pf| pfv)?\z/
      ),
      negation: /\b(nao|nunca|nem)\b/
    }.freeze

    EN = {
      ask: Regexp.union(
        /\b(talk|speak|chat)\b.*\b(to|with)\b.*\b(a |an )?(human|person|agent|representative|someone)\b/,
        /\breal person\b/,
        /\bhuman (agent|support)\b/,
        /\A(a |an )?(human|agent|person|representative)( please)?\z/
      ),
      negation: /\b(don'?t|do not|not|never)\b/
    }.freeze

    DEFAULT = new(
      # RN-42: configurável por marca e idioma no bloco 12.
      transfer_notice_texts: {
        "pt-BR" => "Estou te transferindo para um especialista. Ele já recebeu o histórico da nossa conversa.",
        "en" => "I'm transferring you to a specialist. They already have the history of our conversation."
      }.freeze,
      human_request_patterns: { "pt-BR" => PT_BR, "en" => EN }.freeze,
      # RN-41: o cliente já esperou mais que o normal.
      priority_raising_reasons: %w[prazo_do_turno teto_do_ciclo publicacao_falhou falha_de_integracao].freeze,
      # RN-33, item 6: uma troca é um turno com `reply` aplicado na atribuição atual da IA (AgentActions::Apply).
      exchanges_limit: 10
    )

    def self.for(_brand) = DEFAULT
  end
end
