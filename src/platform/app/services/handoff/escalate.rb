# Handoff mínimo do bloco 08 (interface combinada, item 1; 07, seção 3.2 "Transferência e ordem de entrega";
# RN-33, RN-46, RF-36).
#
#   Handoff::Escalate.call(outbox_event_id) # => Result(status:, reason:)
#
# Chamado pelo OutboxJob para o item "handoff.requested", gravado por qualquer gatilho (Handoff::Request).
# Uma transação, com o atendimento travado antes do item (a ordem do resto do sistema) e escopo pela marca do
# item (invariante 6). O pedido vale só se a atribuição for a mesma do pedido e o caso ainda estiver com a IA;
# senão o item encerra como descarte auditado (`handoff.discarded`). Válido:
#
# - o caso vai a `aguardando_humano`, na fila padrão da marca com a versão atual dela (sem fila padrão, escala
#   sem fila e registra `queue_missing`: o cliente não pode ficar preso na IA por falta de configuração);
# - `assignment_version + 1`: respostas, avisos e timeouts da atribuição antiga perdem a validade;
# - encerra o ciclo da IA (first_pending_*, dispatch_due_at, progress_due_at, ai_deadline_at);
# - turnos `eligible` → `expired` (`ai_turn.expired`, motivo handoff);
# - entregas `pending` da atribuição à IA (reply, resolution, progress) → `cancelled` (`delivery.cancelled`,
#   motivo handoff), com os itens de envio encerrados; as `sending` ficam para a conciliação (07, seção 3.2);
# - `ticket.escalated` com o motivo, a origem, as versões da atribuição e a fila.
#
# Nada externo aqui (invariante 2). O broadcast no painel, o aviso de transferência (RN-42), o resumo (RN-39)
# e a atribuição a analista são do bloco 10.
module Handoff
  class Escalate
    Result = Data.define(:status, :reason)

    AI_KINDS = %w[reply resolution progress].freeze
    REASON = "handoff".freeze

    def self.call(...) = new(...).call

    def initialize(outbox_event_id)
      @id = outbox_event_id
    end

    def call
      ActiveRecord::Base.transaction do
        @item = OutboxEvent.find_by(id: @id)
        next Result.new(status: :skipped, reason: nil) unless @item

        @ticket = Ticket.lock.find_by(id: @item.ticket_id, brand_id: @item.brand_id)
        @item.lock!
        next Result.new(status: :already_done, reason: nil) if @item.completed_at

        decide
      end
    end

    private

    attr_reader :item, :ticket

    def payload = item.payload
    def now = @now ||= Time.current

    def decide
      return discard("atendimento_inexistente") unless ticket

      expected = payload["assignment_version"]
      if expected != ticket.assignment_version
        return discard("atribuicao_mudou", expected_version: expected, current_version: ticket.assignment_version)
      end
      return discard("fora_da_ia", state: ticket.state) unless ticket.with_ai?

      escalate
    end

    def escalate
      from = ticket.assignment_version
      queue = HelpdeskQueue.find_by(brand_id: ticket.brand_id, is_default: true, active: true)
      queue_version = queue&.current_version&.version
      ticket.update_columns(state: "aguardando_humano", queue_id: queue&.id, queue_version:, assignee_id: nil,
                            assignment_version: from + 1, first_pending_seq: nil, first_pending_at: nil,
                            dispatch_due_at: nil, progress_due_at: nil, ai_deadline_at: nil, updated_at: now)
      expire_turns
      cancel_deliveries
      complete
      audit("ticket.escalated", reason: payload["reason"], source: payload["source"], turn: payload["turn"],
                                first_pending_seq: payload["first_pending_seq"], from_assignment_version: from,
                                to_assignment_version: from + 1, queue_id: queue&.id, queue_version:,
                                queue_missing: queue.nil?)
      JsonLog.info("ticket.escalated", trace_id: item.trace_id, ticket_id: ticket.id, reason: payload["reason"],
                                       source: payload["source"], queue_id: queue&.id)
      Result.new(status: :escalated, reason: payload["reason"])
    end

    def expire_turns
      turns = ticket.ai_turns.eligible.where(brand_id: ticket.brand_id).to_a
      return if turns.empty?

      AiTurn.where(id: turns.map(&:id), status: "eligible").update_all(status: "expired", updated_at: now)
      turns.each { audit("ai_turn.expired", turn: _1.turn, deadline_at: _1.deadline_at.utc.iso8601(3), reason: REASON) }
    end

    def cancel_deliveries
      deliveries = Delivery.where(brand_id: ticket.brand_id, ticket_id: ticket.id, status: "pending", kind: AI_KINDS)
                           .where.not(ai_assignment_version: nil).order(:seq).to_a
      deliveries.each do |delivery|
        delivery.update!(status: "cancelled", lease_until: nil, last_error: REASON)
        OutboxEvent.where(brand_id: ticket.brand_id, dedup_key: "delivery:#{delivery.delivery_id}", completed_at: nil)
                   .update_all(completed_at: now, lease_until: nil, last_error: REASON)
        AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type: "delivery.cancelled",
                           trace_id: delivery.trace_id, data: { delivery_id: delivery.delivery_id, seq: delivery.seq, reason: REASON })
      end
    end

    def discard(reason, **data)
      complete(last_error: reason)
      audit("handoff.discarded", reason:, **data)
      JsonLog.info("handoff.discarded", trace_id: item.trace_id, outbox_event_id: item.id, reason:)
      Result.new(status: :discarded, reason:)
    end

    def complete(last_error: nil) = item.update!(completed_at: now, lease_until: nil, last_error:)

    def audit(event_type, **data)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: ticket&.id, actor_type: "system", event_type:,
                         trace_id: item.trace_id,
                         data: { outbox_event_id: item.id, request_reason: payload["reason"] }.merge(data))
    end
  end
end
