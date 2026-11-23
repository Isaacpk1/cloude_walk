# Resposta do analista ao cliente (RF-46; 07, seção 3.6): mensagem `outbound` de `analyst`, entrega `analyst` e item
# `delivery.requested` na mesma transação. Só o responsável responde, com o caso em `com_analista`.
#
#   Human::Reply.call(ticket_id:, brand_id:, user:, text:) # => Result(status: :sent | :rejected, reason:, delivery_event_id:)
module Human
  class Reply < Action
    private

    def validate = @rest[:text].to_s.strip.empty? ? "texto_vazio" : nil

    def perform
      message = create_message(@rest[:text].to_s.strip, internal: false)
      delivery, event = request_delivery(message, kind: "analyst")
      audit("analyst.replied", message_id: message.id, delivery_id: delivery.delivery_id, seq: message.seq)
      Result.new(status: :sent, delivery_event_id: event.id)
    end
  end
end
