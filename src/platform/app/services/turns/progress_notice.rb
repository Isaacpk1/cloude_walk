# Aviso de progresso ao cliente pela ação "progress.notice" do outbox (RN-57; 07, seção 3.4, "Regras de tempo";
# ADR-016). O scheduler (Deadlines::ProgressDue) grava a ação aos 15 s desde a primeira mensagem pendente.
#
#   Turns::ProgressNotice.call(outbox_event_id) # => Result(status:, next_attempt_at:)
#
# Uma transação, com a linha do atendimento travada antes do item (a mesma ordem do resto do sistema). Revalida
# pelo relógio do banco, lido depois do lock: o aviso só sai "enquanto o mesmo ciclo estiver pendente, com a IA e
# antes do timeout" (07, seção 3.4). Motivos de descarte, auditados em progress.notice_discarded:
#
# - fora_da_ia: o caso saiu da IA ou a atribuição mudou desde o registro do aviso;
# - resposta_aplicada: uma resposta aplicada já cobre o ciclo (a resposta chegou antes do aviso);
# - ciclo_encerrado: o ciclo acabou sem resposta aplicada (ex.: handoff);
# - ciclo_novo: outro ciclo começou (o prazo do ciclo novo fica intacto);
# - handoff_pedido: já há um pedido de handoff para a atribuição atual (interface do bloco 08, item 1);
# - prazo_vencido: o relógio do banco chegou ao teto do ciclo (ai_deadline_at, RN-46).
#
# Se vale, grava a saída como as demais (07, seção 3.2; ADR-021): a mensagem do bot com o próximo seq, pelo canal e
# pela conta da última mensagem do cliente (RF-06), com o texto do idioma da marca (Turns::Policy); a entrega
# `progress` pending com ai_first_pending_seq e ai_assignment_version; o item delivery.requested (o envio é do
# Deliveries::Send); as auditorias delivery.requested e progress.notice_sent. Sobe context_version (saída visível,
# ADR-022) e zera progress_due_at. O ciclo continua pendente: o aviso não é a resposta.
#
# A corrida com a resposta (AgentActions::Apply) é decidida pelo lock do atendimento: quem trava primeiro grava.
# Resposta antes: o aviso é descartado (resposta_aplicada). Aviso antes: ele tem seq menor que a resposta, e o Apply
# cancela a entrega do aviso que ainda estiver pending. Nunca sai um aviso depois da resposta aplicada do ciclo.
#
# Repetir o item é seguro: um item concluído não faz nada, e a chave da ação já garante um aviso por ciclo.
module Turns
  class ProgressNotice
    Result = Data.define(:status, :next_attempt_at) do
      def initialize(next_attempt_at: nil, **) = super
    end

    DISCARD_EVENT = Deadlines::ProgressDue::DISCARD_EVENT
    DELIVERY_EVENT = Deliveries::Send::EVENT_TYPE

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      result = ActiveRecord::Base.transaction { process }
      wake_sender
      result
    end

    private

    attr_reader :ticket, :item

    def process
      item = OutboxEvent.find_by(id: @outbox_event_id)
      return Result.new(status: :already_done) unless item && item.completed_at.nil?

      # Invariante 6: o atendimento pela marca do item. Ordem das travas: atendimento, depois o item.
      @ticket = Ticket.lock(Ticket::ROW_LOCK).find_by(id: item.ticket_id, brand_id: item.brand_id)
      item.lock!
      return Result.new(status: :already_done) if item.completed_at
      return missing_ticket(item) unless @ticket

      @item = item
      @now = DatabaseClock.now # depois do lock
      decide
    end

    # Sem o atendimento na marca do item, nada a fazer: encerra o item, senão a recuperação o reoferece sem fim.
    def missing_ticket(item)
      item.update!(completed_at: Time.current, lease_until: nil, last_error: "atendimento_inexistente")
      JsonLog.info("progress.notice_discarded", trace_id: item.trace_id, outbox_event_id: item.id, reason: "atendimento_inexistente")
      Result.new(status: :discarded)
    end

    def cycle_seq = item.payload.fetch("first_pending_seq")

    def decide
      reason = discard_reason
      return discard(reason) if reason
      return not_due if ticket.progress_due_at && ticket.progress_due_at > @now

      send_notice
    end

    def discard_reason
      return "fora_da_ia" if !ticket.with_ai? || item.payload.fetch("assignment_version") != ticket.assignment_version
      return "resposta_aplicada" if Deadlines::ProgressDue.answered?(ticket, cycle_seq)
      return "ciclo_encerrado" unless ticket.first_pending_seq
      return "ciclo_novo" if ticket.first_pending_seq != cycle_seq
      return "handoff_pedido" if handoff_requested?

      "prazo_vencido" if ticket.ai_deadline_at && @now >= ticket.ai_deadline_at
    end

    # Interface do bloco 08, item 1: um pedido de handoff por atribuição, pela chave.
    def handoff_requested? = Handoff::Request.pending?(ticket)

    # O relógio do banco ainda não chegou ao prazo (relógio do scheduler adiantado): volta no prazo.
    def not_due
      item.update!(next_attempt_at: ticket.progress_due_at, lease_until: nil)
      Result.new(status: :not_due, next_attempt_at: ticket.progress_due_at)
    end

    def discard(reason)
      # Só o prazo do próprio ciclo: um ciclo novo tem o seu.
      ticket.update_columns(progress_due_at: nil) if ticket.first_pending_seq == cycle_seq
      complete(last_error: reason)
      audit(DISCARD_EVENT, reason:, source: "worker")
      JsonLog.info("progress.notice_discarded", trace_id: item.trace_id, ticket_id: ticket.id, reason:)
      Result.new(status: :discarded)
    end

    def send_notice
      origin = last_customer_message
      seq = Message.where(ticket_id: ticket.id, brand_id: ticket.brand_id).maximum(:seq).to_i + 1
      message = Message.create!(
        brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "bot", body: text, seq:,
        channel: origin.channel, provider_account: origin.provider_account, external_id: nil, trace_id: item.trace_id,
        received_at: @now
      )
      # ADR-022, RF-33: saída visível ao cliente muda o que a IA veria. Linha travada.
      context_version = ticket.bump_context_version!
      delivery = Delivery.create!(
        brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel, provider_account: message.provider_account,
        kind: "progress", status: "pending", ai_assignment_version: ticket.assignment_version,
        ai_first_pending_seq: cycle_seq, trace_id: item.trace_id
      ).reload # delivery_id vem do padrão do banco
      @delivery_event = OutboxEvent.create!(
        brand_id: ticket.brand_id, ticket:, event_type: DELIVERY_EVENT, dedup_key: "delivery:#{delivery.delivery_id}",
        payload: { delivery_id: delivery.delivery_id, ticket_id: ticket.id, seq: }, trace_id: item.trace_id,
        next_attempt_at: Time.current
      )
      ticket.update_columns(progress_due_at: nil)
      complete
      audit(DELIVERY_EVENT, delivery_id: delivery.delivery_id, message_id: message.id, seq:, kind: "progress", context_version:)
      audit("progress.notice_sent", delivery_id: delivery.delivery_id, message_id: message.id, seq:)
      JsonLog.info("progress.notice_sent", trace_id: item.trace_id, ticket_id: ticket.id, delivery_id: delivery.delivery_id, seq:)
      Result.new(status: :sent)
    end

    def text = Turns::Policy.for_ticket(ticket).progress_notice_text(ticket.brand.locale)

    def last_customer_message
      Message.where(ticket_id: ticket.id, brand_id: ticket.brand_id, direction: "inbound", author_type: "customer")
             .order(seq: :desc).first!
    end

    def complete(last_error: nil) = item.update!(completed_at: Time.current, lease_until: nil, last_error:)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type:, trace_id: item.trace_id,
                         data: { outbox_event_id: item.id, first_pending_seq: cycle_seq,
                                 assignment_version: item.payload["assignment_version"] }.merge(data))
    end

    # Depois do commit (invariante 2). Se o Redis falhar, a entrega já está gravada e a recuperação reoferece o item.
    def wake_sender
      return unless @delivery_event

      OutboxJob.perform_later(@delivery_event.id)
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", trace_id: @delivery_event.trace_id, event_id: @delivery_event.id, error: e.class.name)
    end
  end
end
