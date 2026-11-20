# Consumer fino de helpdesk.agent.inbound.v1 (docs/10, seção 3.3): traduz a mensagem do Kafka
# (corpo bruto e cabeçalhos) e chama o AgentMock::Responder.
#
# Marca o offset de cada evento depois de tratado. Se a publicação da ação não for confirmada,
# a exceção sobe: o Karafka pausa a partição e volta a entregar a partir do evento que falhou,
# sem reprocessar os anteriores do lote (07, seção 6).
class InboundConsumer < Karafka::BaseConsumer
  def consume
    messages.each do |message|
      responder.call(payload: message.raw_payload, headers: message.headers)
      mark_as_consumed(message)
    end
  end

  private

  def responder
    @responder ||= AgentMock::Responder.new(producer:, config: AgentMock.config, log: AgentMock.log, clock: AgentMock.clock)
  end
end
