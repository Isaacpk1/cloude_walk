# Consumer de helpdesk.agent.dlq.v1 (grupo platform-dlq; RF-34, RF-37, RN-45; interface dos blocos 08 e 09,
# item 4). Só traduz a mensagem do Kafka e chama DeadLetters::Record, que grava o espelho em dead_letters e
# aplica a RN-45 numa transação.
#
# Offset (RNF-14): cada mensagem é marcada como consumida só depois de o serviço voltar, isto é, depois do commit.
# Erro de banco sobe: a mensagem não é marcada e volta; a linha é idempotente por topic/partition/offset.
class DeadLettersConsumer < Karafka::BaseConsumer
  def consume
    messages.each do |message|
      DeadLetters::Record.call(topic: message.topic, partition: message.partition, offset: message.offset,
                               payload: message.raw_payload, headers: message.headers, key: message.raw_key)
      mark_as_consumed(message)
    end
  end
end
