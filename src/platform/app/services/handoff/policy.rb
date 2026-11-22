# Parâmetros do handoff num lugar só (07, seção 3.2; 06, parâmetros).
#
#   policy = Handoff::Policy.for(brand)
#   policy.transfer_notice_text(brand.locale)          # aviso de transferência (RN-42)
#   policy.human_request?(text, brand.locale)          # pedido explícito de humano (RN-34)
#   policy.raise_priority?(reason)                     # RN-41: tempo ou falha de integração sobem um nível
#   policy.raised_priority(ticket.priority)
#
# Hoje toda marca usa os padrões. No bloco 12, `for` passa a ler a configuração versionada da marca (textos e
# expressões por marca e idioma, RN-34 e RN-42); quem chama não muda.
module Handoff
  Policy = Data.define(:transfer_notice_texts, :human_request_patterns, :priority_raising_reasons) do
    # Idioma sem texto é erro, como no aviso de progresso: um padrão esconderia uma marca nova sem o aviso.
    def transfer_notice_text(locale) = transfer_notice_texts.fetch(locale)

    # RN-34: o pedido é a mensagem inteira pedir um humano, não a menção a uma pessoa. Compara sem acento e sem
    # diferenciar maiúsculas, contra as expressões do idioma da marca.
    def human_request?(text, locale)
      return false if text.blank?

      normalized = I18n.transliterate(text.to_s).downcase.squish
      human_request_patterns.fetch(locale, []).any? { normalized.match?(_1) }
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

    PT_BR = [
      /\b(quero|queria|preciso|posso|gostaria de|me (passa|transfere|coloca)( pra| para)?)\b.*\b(falar|conversar|atendimento|atendente|humano|pessoa)/,
      /\bfalar com (um|uma|algum|alguma|alguem)?\s*(atendente|humano|pessoa|alguem|especialista)/,
      /\b(passa|transfere|coloca)\b.*\b(pra|para)\b.*\b(um|uma)\b\s*(atendente|humano|pessoa)/,
      /\batendimento humano\b/,
      /\b(um|uma) (atendente|pessoa) de verdade\b/
    ].freeze

    EN = [
      /\b(talk|speak|chat)\b.*\b(to|with)\b.*\b(a |an )?(human|person|agent|representative|someone)\b/,
      /\breal person\b/,
      /\bhuman (agent|support)\b/
    ].freeze

    DEFAULT = new(
      # RN-42: configurável por marca e idioma no bloco 12.
      transfer_notice_texts: {
        "pt-BR" => "Estou te transferindo para um especialista. Ele já recebeu o histórico da nossa conversa.",
        "en" => "I'm transferring you to a specialist. They already have the history of our conversation."
      }.freeze,
      human_request_patterns: { "pt-BR" => PT_BR, "en" => EN }.freeze,
      # RN-41: o cliente já esperou mais que o normal.
      priority_raising_reasons: %w[prazo_do_turno teto_do_ciclo publicacao_falhou falha_de_integracao].freeze
    )

    def self.for(_brand) = DEFAULT
  end
end
