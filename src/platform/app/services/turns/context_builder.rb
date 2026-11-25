# Conteúdo do contexto de um turno pela RN-49 (07, seção 3.4, "Contexto completo, de forma verificável";
# RF-33, RF-53). Roda dentro da transação do Turns::Open, com a linha do atendimento travada.
#
#   Turns::ContextBuilder.call(ticket:, policy:, now:) # => Context
#
# Nesta ordem: todas as mensagens do cliente sem resposta, por inteiro; o histórico visível até 20
# mensagens, cortado das mais antigas até o contexto inteiro caber em `context_chars_limit`; e os
# últimos 3 atendimentos do mesmo cliente nos últimos 90 dias, na mesma marca. O resumo do próprio
# atendimento (`summary.covers_until_seq`) nasce no bloco 10: sem ele, o histórico termina logo antes
# da primeira pendente e é contíguo, então nada cai num vão. Tamanho = caracteres de `text`.
module Turns
  class ContextBuilder
    Context = Data.define(:pending, :history, :previous_tickets) do
      def pending_chars = pending.sum { _1.body.length }
      def chars = pending_chars + history.sum { _1.body.length } + previous_tickets.sum { _1.summary.length }
    end
    PreviousTicket = Data.define(:id, :summary)

    HISTORY_LIMIT = 20                  # RN-49
    PREVIOUS_TICKETS_LIMIT = 3          # RN-49, RF-53
    PREVIOUS_TICKETS_WINDOW = 90.days   # RN-49, RF-53

    def self.call(...) = new(...).call

    def initialize(ticket:, policy:, now:)
      @ticket = ticket
      @policy = policy
      @now = now
    end

    def call
      context = Context.new(pending:, history: recent_history, previous_tickets:)
      history = context.history.dup
      history.shift while history.any? && context.with(history:).chars > @policy.context_chars_limit
      context.with(history:)
    end

    private

    attr_reader :ticket

    # "Sem resposta": mensagens do cliente depois da última saída visível ao cliente. O aviso de progresso (RN-57)
    # não responde: as mensagens do ciclo continuam pendentes depois dele.
    def pending
      @pending ||= begin
        answered_until = messages.where(direction: "outbound", internal: false)
                                 .where.not(id: Delivery.where(ticket_id: ticket.id, brand_id: ticket.brand_id, kind: "progress")
                                                        .select(:message_id))
                                 .maximum(:seq).to_i
        messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).order(:seq).to_a
      end
    end

    def recent_history
      first_pending = pending.first&.seq || (ticket.latest_customer_seq + 1)
      messages.where(internal: false).where(seq: ...first_pending).reorder(seq: :desc).limit(HISTORY_LIMIT).to_a.reverse
    end

    def messages = Message.where(ticket_id: ticket.id, brand_id: ticket.brand_id)

    # Invariante 6: mesma marca e mesmo cliente. Ainda não há resumo gravado (ticket_summaries, bloco 10):
    # vai só o que existe, sem inventar conteúdo.
    def previous_tickets
      Ticket.where(brand_id: ticket.brand_id, customer_id: ticket.customer_id).where.not(id: ticket.id)
            .where(created_at: (@now - PREVIOUS_TICKETS_WINDOW)..ticket.created_at)
            .order(created_at: :desc, id: :desc).limit(PREVIOUS_TICKETS_LIMIT)
            .map do |previous|
        saved = TicketSummary.where(brand_id: ticket.brand_id, ticket_id: previous.id).order(resolved_at: :desc, id: :desc).first
        PreviousTicket.new(id: previous.id, summary: saved&.body || placeholder_summary(previous))
      end
    end

    def placeholder_summary(previous)
      opened_on = previous.created_at.in_time_zone(ticket.brand.timezone).to_date.iso8601
      parts = [ "Sem resumo gravado.", "Canal: #{previous.channel}.", "Aberto em #{opened_on}.", "Estado: #{previous.state}." ]
      parts << "Categoria: #{previous.category}." if previous.category
      parts.join(" ")
    end
  end
end
