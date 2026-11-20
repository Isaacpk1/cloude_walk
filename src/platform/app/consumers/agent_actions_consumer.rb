# Consumer de helpdesk.agent.outbound.v1 (RF-31; 07, seção 3.1, passo 6; docs/10). Só traduz a mensagem do
# Kafka e chama o serviço, que valida o contrato e grava processed_events na transação do efeito.
#
# Offset (RNF-14; 07, seção 6, "consumer cai no meio"): cada mensagem é marcada como consumida só depois de
# o serviço voltar, isto é, depois do commit. Erro de banco sobe como exceção: a mensagem não é marcada e o
# Karafka a entrega de novo; a idempotência (RN-47) absorve o que já tinha sido gravado.
class AgentActionsConsumer < Karafka::BaseConsumer
  def consume
    messages.each do |message|
      AgentActions::Apply.call(message.raw_payload, traceparent: header(message, "traceparent"))
      mark_as_consumed(message)
    end
  end

  private

  # O payload vai cru: o serviço precisa do corpo como chegou para a DLQ, inclusive quando não é JSON.
  def header(message, name) = Array(message.headers[name]).first
end
