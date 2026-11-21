# Fase de agrupamento (RN-55; 07, seção 3.4): o atendimento tem ciclo pendente e o turno da última
# mensagem ainda não abriu. `pending_seqs` são as mensagens que o próximo turno vai levar. O turno sai no
# `dispatch_due_at`: o fim da janela do canal depois da última mensagem ou o teto (`ceiling_at`, primeira
# pendente + 4 s), o que vier primeiro. `prevails` diz qual dos dois vale (:window, :ceiling ou :none,
# sem janela no e-mail). `overdue`: o horário passou e o scheduler ainda não abriu o turno.
class ConversationView::Grouping < Data.define(:pending_seqs, :channel, :window_ms, :dispatch_due_at, :ceiling_at,
                                               :prevails, :overdue)
  PREVAILS = %i[window ceiling none].freeze

  def initialize(pending_seqs:, prevails:, **rest)
    raise ArgumentError, "prevails desconhecido: #{prevails}" unless PREVAILS.include?(prevails)

    super(pending_seqs: pending_seqs.sort.freeze, prevails:, **rest)
  end

  def no_window? = prevails == :none

  def summary
    rule = case prevails
    when :none then "sem janela: sai na próxima volta do scheduler"
    when :ceiling then "janela de #{window_ms} ms no #{channel}; vale o teto de 4 s desde a primeira mensagem pendente"
    else "janela de #{window_ms} ms no #{channel}; vale a janela, antes do teto"
    end
    overdue ? "#{rule}. Horário previsto passou: aguardando o scheduler abrir o turno" : rule
  end
end
