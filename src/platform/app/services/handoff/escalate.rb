# Handoff pelo outbox (07, seção 3.2 "Transferência e ordem de entrega"; RN-33, RN-46, RF-36; bloco 10: RF-42,
# RF-43, RN-14, RN-17, RN-38, RN-39, RN-41, RN-42).
#
#   Handoff::Escalate.call(outbox_event_id) # => Result(status:, reason:, delivery_event_id:, summary_event_id:)
#
# Chamado pelo OutboxJob para o item "handoff.requested", gravado por qualquer gatilho (Handoff::Request).
# Uma transação, com o atendimento travado antes do item (a ordem do resto do sistema) e escopo pela marca do
# item (invariante 6). O pedido vale só se a atribuição for a mesma do pedido e o caso ainda estiver com a IA;
# senão o item encerra como descarte auditado (`handoff.discarded`, motivo `atribuicao_mudou`, `ja_escalado` se
# o caso já está em `aguardando_humano`, ou `fora_da_ia`; `atendimento_inexistente` sem atendimento na marca do
# item). Válido:
#
# - fila (RF-42, RN-17): a de escalas ativa da marca (`queue_kind: escalation`); sem ela, a padrão (`default`);
#   sem nenhuma, escala sem fila (`missing`, `queue_missing`): o cliente não fica preso na IA por configuração.
#   Grava a versão corrente da fila (`queue_version`);
# - prioridade (RN-41, RN-14): escalação por tempo ou falha de integração sobe um nível (`ticket.priority_raised`
#   com from, to e reason); nunca desce;
# - `assignment_version + 1`: respostas, avisos e timeouts da atribuição antiga perdem a validade;
# - encerra o ciclo da IA (first_pending_*, dispatch_due_at, progress_due_at, ai_deadline_at) e zera
#   `ai_turns_count` (RN-33, item 6);
# - turnos `eligible` → `expired` (`ai_turn.expired`, motivo handoff);
# - entregas `pending` da atribuição à IA (reply, resolution, progress) → `cancelled` (`delivery.cancelled`,
#   motivo handoff), com os itens de envio encerrados; as `sending` ficam para a conciliação (07, seção 3.2);
# - aviso de transferência (RN-42, RF-43): mensagem do sistema com o próximo `seq`, no canal e na conta da última
#   mensagem do cliente, entrega `handoff_notice` sem `ai_assignment_version` (não é cancelável como saída da IA)
#   e `delivery.requested` no outbox. A ordem é do Deliveries::Send: uma `sending` anterior (em curso ou em
#   conciliação) segura o aviso até um resultado definitivo (RN-38). Sem mensagem do cliente, não há destino:
#   audita `handoff.notice_skipped`;
# - resumo (RN-39, RN-40): o do agente (payload "summary") vira HandoffSummary disponível na hora; sem ele, o
#   item `handoff.summary` pede à plataforma que monte o resumo (Handoff::Summarize), sem segurar a fila;
# - `ticket.escalated` com o motivo, a origem, as versões da atribuição, a fila, a prioridade, o aviso e o resumo.
#
# Nada externo aqui (invariante 2): o Result leva os ids dos itens gravados, que o OutboxJob acorda depois do
# commit. A atribuição a analista é do bloco 13.
module Handoff
  class Escalate
    Result = Data.define(:status, :reason, :delivery_event_id, :summary_event_id) do
      def initialize(status:, reason:, delivery_event_id: nil, summary_event_id: nil) = super

      # Itens gravados nesta transação, para o OutboxJob acordar depois do commit.
      def wake_ids = [ delivery_event_id, summary_event_id ].compact
    end

    AI_KINDS = %w[reply resolution progress].freeze
    REASON = "handoff".freeze
    DELIVERY_EVENT = "delivery.requested".freeze
    SUMMARY_EVENT = "handoff.summary".freeze

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
      return discard(ticket.state == "aguardando_humano" ? "ja_escalado" : "fora_da_ia", state: ticket.state) unless ticket.with_ai?
      # 07, seção 6: caso já respondido não escala (defesa; o pedido já expira os turnos eligible).
      return discard("turno_applied", turn: payload["turn"]) if requested_turn_applied?

      escalate
    end

    def requested_turn_applied?
      payload["turn"] && ticket.ai_turns.where(brand_id: ticket.brand_id, turn: payload["turn"], status: "applied").exists?
    end

    def escalate
      from = ticket.assignment_version
      queue, queue_kind = target_queue
      queue_version = queue&.current_version&.version
      priority_from = ticket.priority
      priority_to = raise_priority? ? policy.raised_priority(priority_from) : priority_from
      ticket.update_columns(state: "aguardando_humano", queue_id: queue&.id, queue_version:, assignee_id: nil,
                            assignment_version: from + 1, first_pending_seq: nil, first_pending_at: nil,
                            dispatch_due_at: nil, progress_due_at: nil, ai_deadline_at: nil, ai_turns_count: 0,
                            priority: priority_to, updated_at: now)
      audit("ticket.priority_raised", from: priority_from, to: priority_to, reason: payload["reason"]) if priority_to != priority_from
      expire_turns
      cancel_deliveries
      notice = request_transfer_notice
      summary_status = record_summary(from)
      complete
      audit("ticket.escalated", reason: payload["reason"], source: payload["source"], turn: payload["turn"],
                                first_pending_seq: payload["first_pending_seq"], from_assignment_version: from,
                                to_assignment_version: from + 1, queue_id: queue&.id, queue_version:, queue_kind:,
                                queue_missing: queue.nil?, priority_from:, priority_to:,
                                transfer_delivery_id: notice&.delivery_id, transfer_seq: notice&.seq, summary_status:)
      JsonLog.info("ticket.escalated", trace_id: item.trace_id, ticket_id: ticket.id, reason: payload["reason"],
                                       source: payload["source"], queue_id: queue&.id, queue_kind:)
      Result.new(status: :escalated, reason: payload["reason"], delivery_event_id: @delivery_event_id,
                 summary_event_id: @summary_event_id)
    end

    def policy = @policy ||= Handoff::Policy.for(ticket.brand)
    def raise_priority? = policy.raise_priority?(payload["reason"])

    # RF-42, RN-17: a escalação é um dos três momentos de roteamento. Até o roteamento por regras da escalação
    # (bloco 11), a fila de escalas da marca; sem ela, a padrão. Sempre na marca do atendimento (invariante 6).
    def target_queue
      scope = HelpdeskQueue.where(brand_id: ticket.brand_id, active: true)
      if (queue = scope.find_by(escalation: true)) then [ queue, "escalation" ]
      elsif (queue = scope.find_by(is_default: true)) then [ queue, "default" ]
      else [ nil, "missing" ]
      end
    end

    # RN-42, RF-43: o aviso entra como saída comum, com o próximo seq; o Deliveries::Send só o autoriza depois de
    # toda saída anterior encerrada (RN-38). Sem ai_assignment_version: nenhum cancelamento da IA o alcança.
    def request_transfer_notice
      origin = last_customer_message
      unless origin
        audit("handoff.notice_skipped", reason: "sem_mensagem_do_cliente")
        return
      end

      seq = Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id).maximum(:seq).to_i + 1
      message = Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "system",
                                body: policy.transfer_notice_text(ticket.brand.locale), seq:, channel: origin.channel,
                                provider_account: origin.provider_account, external_id: nil, trace_id: item.trace_id,
                                received_at: now)
      context_version = ticket.bump_context_version! # ADR-022: saída visível ao cliente
      delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                  provider_account: message.provider_account, kind: "handoff_notice", status: "pending",
                                  trace_id: item.trace_id).reload # delivery_id vem do padrão do banco
      @delivery_event_id = OutboxEvent.create!(
        brand_id: ticket.brand_id, ticket:, event_type: DELIVERY_EVENT, dedup_key: "delivery:#{delivery.delivery_id}",
        payload: { delivery_id: delivery.delivery_id, ticket_id: ticket.id, seq: }, trace_id: item.trace_id, next_attempt_at: now
      ).id
      audit(DELIVERY_EVENT, delivery_id: delivery.delivery_id, message_id: message.id, seq:, kind: "handoff_notice",
                            turn: nil, context_until_seq: origin.seq, context_version:)
      delivery
    end

    def last_customer_message
      Message.where(brand_id: ticket.brand_id, ticket_id: ticket.id, direction: "inbound", author_type: "customer")
             .order(seq: :desc).first
    end

    # RN-39, RN-40: o resumo do agente vale na hora; sem ele, a plataforma monta depois (item handoff.summary).
    # Um por handoff: o índice único de handoff_summaries e a chave do item garantem na repetição.
    def record_summary(from)
      if payload["summary"].is_a?(Hash)
        HandoffSummary.insert_all([ { brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: from,
                                      source: "agent", status: "available", fields: payload["summary"].slice(*HandoffSummary::FIELDS),
                                      trace_id: item.trace_id, created_at: now } ],
                                  unique_by: %i[ticket_id from_assignment_version], record_timestamps: false)
        audit("handoff.summary_available", source: "agent", from_assignment_version: from, ms_since_escalated: 0)
        "available"
      else
        request_platform_summary(from)
        "pending"
      end
    end

    def request_platform_summary(from)
      row = { brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: SUMMARY_EVENT, dedup_key: "summary:#{ticket.id}:#{from}",
              payload: { ticket_id: ticket.id, from_assignment_version: from, reason: payload["reason"],
                         escalated_at: now.utc.iso8601(3) },
              trace_id: item.trace_id, next_attempt_at: now, created_at: now }
      @summary_event_id = OutboxEvent.insert_all([ row ], unique_by: :index_outbox_events_on_dedup_key, returning: [ :id ],
                                                          record_timestamps: false).rows.first&.first
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

    # O painel (A3) lê o `data` do pedido mais o motivo do descarte e o motivo pedido.
    def discard(reason, **data)
      complete(last_error: reason)
      AuditEvent.create!(brand_id: item.brand_id, ticket_id: ticket&.id, actor_type: "system", event_type: "handoff.discarded",
                         trace_id: item.trace_id,
                         data: payload.merge(data.transform_keys(&:to_s))
                                      .merge("outbox_event_id" => item.id, "reason" => reason, "handoff_reason" => payload["reason"]))
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
