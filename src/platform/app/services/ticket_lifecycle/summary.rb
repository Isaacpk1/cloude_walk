module TicketLifecycle
  class Summary
    def self.call(...) = new(...).call

    def initialize(ticket:, reason:)
      @ticket = ticket
      @reason = reason
    end

    def call
      messages = Message.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, internal: false)
      problem = messages.where(direction: "inbound", author_type: "customer").order(:seq).first&.body
      reply = messages.where(direction: "outbound").joins(:delivery)
                      .where(deliveries: { status: "delivered", kind: %w[reply analyst resolution] }).order(seq: :desc).first&.body
      tools = AiTurn.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, status: "applied").pluck(:response)
                    .flat_map { Array(_1&.[]("tool_calls")).map { |call| call["tool"] } }.compact.uniq
      text = "Problema: #{problem.to_s.truncate(500)}. Ações: #{tools.join(', ').presence || 'sem consultas registradas'}. " \
             "Última resposta entregue: #{reply.to_s.truncate(500).presence || 'sem resposta entregue'}. Resolução: #{@reason}."
      text = text.gsub(Handoff::Summarize::EMAIL, "[e-mail]").gsub(Handoff::Summarize::DOCUMENT, "[documento]")
      text = text.gsub(Handoff::Summarize::PHONE_CANDIDATE) { |part| part.count("0-9").between?(10, 13) ? "[telefone]" : part }
      name = @ticket.customer.display_name.to_s
      parts = name.match?(Handoff::Summarize::PROVISIONAL_NAME) ? [] : name.split.grep(/\A\p{L}{3,}\z/)
      parts.each do |part|
        text = text.gsub(/(?<![\p{L}_])#{Regexp.escape(part)}(?![\p{L}_])/i, "#{part[0]}***")
      end
      text.truncate(1600)
    end
  end
end
