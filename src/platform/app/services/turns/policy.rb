# Tempos do atendimento pela IA num lugar só (ADR-020; 06, parâmetros).
#
#   policy = Turns::Policy.for(brand)
#   policy.window_for("chat")                      # janela de agrupamento (RN-55)
#   policy.turn_deadline_at(opened_at:, cycle_deadline_at:)
#   policy.pending_chars_limit / policy.context_chars_limit  # tamanho do contexto (RN-49)
#   policy.progress_notice / policy.progress_notice_text(brand.locale) # aviso de progresso (RN-57)
#
# Hoje toda marca usa os padrões. No bloco 12, `for` passa a ler a configuração versionada da marca,
# editada pelo supervisor e com limites; quem chama não muda. Os prazos já ficam gravados no
# atendimento e no turno, então mudar a configuração só afeta ciclos novos.
module Turns
  Policy = Data.define(:windows, :ceiling, :turn_deadline, :cycle_deadline, :progress_notice,
                       :pending_chars_limit, :context_chars_limit, :progress_notice_texts, :version) do
    # Canal desconhecido é erro: uma janela padrão esconderia um canal novo sem parâmetro definido.
    def window_for(channel) = windows.fetch(channel)

    # RN-57: texto do aviso de progresso no idioma da marca (brands.locale). Idioma sem texto é erro, como canal
    # sem janela: um texto padrão esconderia uma marca nova sem o aviso definido.
    def progress_notice_text(locale) = progress_notice_texts.fetch(locale)

    # ADR-020: 20 s desde a abertura do turno, sem passar do teto do ciclo.
    def turn_deadline_at(opened_at:, cycle_deadline_at:) = [ opened_at + turn_deadline, cycle_deadline_at ].min

    def to_snapshot
      { "chat_window" => windows.fetch("chat").to_f, "whatsapp_window" => windows.fetch("whatsapp").to_f,
        "email_window" => windows.fetch("email").to_f, "ceiling" => ceiling.to_f, "turn_deadline" => turn_deadline.to_f,
        "cycle_deadline" => cycle_deadline.to_f, "progress_notice" => progress_notice.to_f, "version" => version }
    end
  end

  class Policy
    DEFAULT = new(
      version: 0,
      windows: { "chat" => 1.5.seconds, "whatsapp" => 1.5.seconds, "email" => 0.seconds }.freeze, # RN-55
      ceiling: 4.seconds,          # RN-55: teto da janela desde a primeira mensagem pendente
      turn_deadline: 20.seconds,   # RN-46, ADR-020: prazo de cada turno
      cycle_deadline: 60.seconds,  # RN-46, ADR-020: teto do ciclo, não reinicia
      progress_notice: 15.seconds, # RN-57
      # RN-49 (07, seção 3.4): caracteres de texto. Acima do limite das pendentes o turno não abre; o
      # histórico perde as mensagens mais antigas até o contexto inteiro caber.
      pending_chars_limit: 16_000,
      context_chars_limit: 32_000,
      # RN-57: o aviso de progresso, por idioma (InfinitePay pt-BR, JIM inglês). Configurável por marca no bloco 12.
      progress_notice_texts: {
        "pt-BR" => "Ainda estou verificando as informações para te responder. Só mais um instante.",
        "en" => "I'm still checking the details to answer you. Just a moment more."
      }.freeze
    )

    def self.for(brand)
      saved = AiPolicyVersion.current_for(brand)
      saved ? from_snapshot(saved.settings.merge("version" => saved.version)) : DEFAULT
    end

    def self.for_ticket(ticket)
      return self.for(ticket.brand) unless ticket.first_pending_seq

      ticket.ai_policy_snapshot.present? ? from_snapshot(ticket.ai_policy_snapshot) : DEFAULT
    end

    def self.from_snapshot(values)
      DEFAULT.with(windows: %w[chat whatsapp email].to_h { [ _1, values.fetch("#{_1}_window").seconds ] }.freeze,
                   ceiling: values.fetch("ceiling").seconds, turn_deadline: values.fetch("turn_deadline").seconds,
                   cycle_deadline: values.fetch("cycle_deadline").seconds, progress_notice: values.fetch("progress_notice").seconds,
                   version: values.fetch("version"))
    end
  end
end
