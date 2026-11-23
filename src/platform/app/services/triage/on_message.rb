# Triagem pelo aviso da ingestão, `message.received` (07, seção 3.1, passo 2; P1: fora da requisição).
#
#   Triage::OnMessage.call(outbox_event_id) # => Result(status:, reason:)
#
# Uma transação, com a linha do atendimento travada antes do item (a mesma ordem da ingestão e do Turns::Open):
# revalida o item, chama o Triage::Run com o `seq` da mensagem e conclui o item na mesma transação do efeito
# (invariante 3). Repetir é seguro: item concluído não faz nada, e o Run só age em caso `novo`.
# Erro na triagem (avaliador fora) desfaz tudo: o item fica aberto e a recuperação (Outbox::Recover) o reoferece.
module Triage
  class OnMessage
    EVENT_TYPE = "message.received".freeze

    Result = Data.define(:status, :reason)

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        item = OutboxEvent.find_by(id: @outbox_event_id, event_type: EVENT_TYPE)
        next Result.new(status: :not_found, reason: nil) unless item

        # Escopo por marca (invariante 6): o item e o atendimento são da mesma marca (chave estrangeira composta).
        ticket = Ticket.lock.find_by!(id: item.ticket_id, brand_id: item.brand_id)
        item.lock!
        next Result.new(status: :already_done, reason: nil) if item.completed_at

        run = Run.call(ticket:, trace_id: item.trace_id, seq: item.payload["seq"])
        item.update!(completed_at: Time.current, lease_until: nil)
        Result.new(status: run.status, reason: run.reason)
      end
    end
  end
end
