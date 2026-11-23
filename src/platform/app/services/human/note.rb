# Nota interna do analista (RN-50, RF-49; 07, seção 3.6): mensagem `internal`, nunca entregue ao cliente. Não gera
# entrega nem item no outbox e não muda a versão do contexto, porque a IA nunca a vê.
module Human
  class Note < Action
    private

    def validate = @rest[:text].to_s.strip.empty? ? "texto_vazio" : nil

    def perform
      message = create_message(@rest[:text].to_s.strip, internal: true)
      audit("analyst.noted", message_id: message.id, seq: message.seq)
      Result.new(status: :noted)
    end
  end
end
