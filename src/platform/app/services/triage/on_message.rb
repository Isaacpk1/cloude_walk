# Triagem pelo aviso da ingestão, `message.received` (07, seção 3.1, passo 2; P1: fora da requisição).
#
#   Triage::OnMessage.call(outbox_event_id) # => Result(status:, reason:)
#
# Uma transação, com a linha do atendimento travada antes do item (a mesma ordem da ingestão e do Turns::Open):
# revalida o item, chama o Triage::Run com o `seq` da mensagem e conclui o item na mesma transação do efeito
# (invariante 3). Repetir é seguro: item concluído não faz nada, e o Run só age em caso `novo`. Com a janela de
# agrupamento aberta (RN-55), não tria: conclui o item e deixa a triagem para o Turns::Open no fim da janela.
# Erro na triagem (avaliador fora) desfaz tudo: o item fica aberto e a recuperação (Outbox::Recover) o reoferece.
module Triage
  class OnMessage
    EVENT_TYPE = "message.received".freeze

    Result = Data.define(:status, :reason, :wake_ids) do
      def initialize(wake_ids: [], **) = super
    end

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

        if window_open?(ticket)
          item.update!(completed_at: Time.current, lease_until: nil)
          next Result.new(status: :deferred, reason: "janela_aberta")
        end

        run = Run.call(ticket:, trace_id: item.trace_id, seq: item.payload["seq"])
        item.update!(completed_at: Time.current, lease_until: nil)
        Result.new(status: run.status, reason: run.reason, wake_ids: run.wake_ids)
      end
    end

    private

    # RN-55: com a janela de agrupamento aberta, a rajada ainda não fechou. Classificar agora decidiria pela 1ª
    # mensagem sozinha ("oi") e a RN-17 impediria corrigir depois. O Turns::Open tria no fim da janela, sob o mesmo
    # lock, com todas as mensagens. O pedido de humano pendente segue para o Run, que só classifica (RN-11).
    def window_open?(ticket)
      ticket.state == "novo" && ticket.dispatch_due_at.present? && ticket.dispatch_due_at > DatabaseClock.now &&
        !Handoff::Request.pending?(ticket)
    end
  end
end
