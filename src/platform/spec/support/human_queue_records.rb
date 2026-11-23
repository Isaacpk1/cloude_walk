# Grava direto no banco, no formato da interface combinada do bloco 10 (/home/claude/tools/common10.md, "Formatos
# combinados"), o que a ingestão (E1), o resumo da plataforma (E2) e o Escalate completo (E3) gravam, para testar o
# painel sem depender desses serviços:
# - record_human_requested: a auditoria customer.human_requested da ingestão (RN-34), com o desfecho;
# - record_full_escalation: o Escalate completo a partir da auditoria do pedido: fila de escalas (ou padrão, ou sem
#   fila), prioridade que sobe pela RN-41 (ticket.priority_raised), o aviso de transferência (mensagem system, entrega
#   handoff_notice pending, delivery.requested no outbox e na auditoria; RN-42), o resumo do agente (HandoffSummary
#   agent + handoff.summary_available com ms 0) ou o item handoff.summary, e ticket.escalated com os campos novos;
# - record_summary: o worker Handoff::Summarize (E2): HandoffSummary platform available ou missing e a auditoria
#   handoff.summary_available / _missing com ms_since_escalated.
# As auditorias levam occurred_at = Time.current, para as durações seguirem o tempo controlado do teste.
module HumanQueueRecordHelpers
  SUMMARY = { "problema" => "Repasse de R$ 1.200 do dia 28 não recebido", "dados_cliente" => "Cliente C***, conta PJ",
              "acoes_tomadas" => "IA consultou o repasse: status pendente", "motivo" => "Cliente pediu humano",
              "pendente" => "Verificar retenção" }.freeze

  def escalation_queue_for(brand, name: "Escalas N1")
    HelpdeskQueue.find_by(brand_id: brand.id, escalation: true) || begin
      queue = create(:queue_record, team: create(:team, brand:), escalation: true)
      queue.publish_version!(name:, created_by: nil, ai_first: false)
      queue.reload
    end
  end

  def record_human_requested(ticket, seq:, outcome:, state: nil, outbox_event_id: nil, trace_id: SecureRandom.hex(16))
    ticket.reload
    queue_audit(ticket, "customer.human_requested", trace_id, "seq" => seq, "state" => state || ticket.state,
                                                              "outcome" => outcome, "outbox_event_id" => outbox_event_id)
  end

  # E3: o que o Handoff::Escalate completo grava na transação do pedido. `queue_kind`: escalation | default | missing.
  # `summary`: os cinco campos vindos do agente, ou nil (resumo pendente, item handoff.summary).
  def record_full_escalation(ticket, request, queue_kind: "escalation", summary: nil, notice: true)
    ticket.reload
    brand = ticket.brand
    queue = { "escalation" => -> { escalation_queue_for(brand) }, "default" => -> { default_queue_for(brand) } }
            .fetch(queue_kind, -> { }).call
    from = ticket.assignment_version
    reason = request.data["reason"]
    policy = Handoff::Policy.for(brand)
    priority_from = ticket.priority
    priority_to = policy.raise_priority?(reason) ? policy.raised_priority(priority_from) : priority_from
    ticket.update_columns(state: "aguardando_humano", queue_id: queue&.id, queue_version: queue&.current_version&.version,
                          priority: priority_to, assignee_id: nil, assignment_version: from + 1, first_pending_seq: nil,
                          first_pending_at: nil, dispatch_due_at: nil, progress_due_at: nil, ai_deadline_at: nil,
                          ai_turns_count: 0)
    AiTurn.where(brand_id: ticket.brand_id, ticket_id: ticket.id, status: "eligible").update_all(status: "expired")
    if priority_to != priority_from
      queue_audit(ticket, "ticket.priority_raised", request.trace_id, "from" => priority_from, "to" => priority_to, "reason" => reason)
    end
    delivery = record_transfer_notice(ticket, request.trace_id) if notice
    summary_status = summary ? record_agent_summary(ticket, from, summary, request.trace_id) : record_summary_item(ticket, from, request)
    queue_audit(ticket, "ticket.escalated", request.trace_id,
                "reason" => reason, "source" => request.data["source"], "turn" => request.data["turn"],
                "first_pending_seq" => request.data["first_pending_seq"], "from_assignment_version" => from,
                "to_assignment_version" => from + 1, "queue_id" => queue&.id, "queue_version" => queue&.current_version&.version,
                "queue_missing" => queue.nil?, "queue_kind" => queue_kind, "priority_from" => priority_from,
                "priority_to" => priority_to, "transfer_delivery_id" => delivery&.delivery_id, "transfer_seq" => delivery&.seq,
                "summary_status" => summary_status)
  end

  # E2: o worker do resumo. `status`: available (com os cinco campos) ou missing (com o motivo).
  def record_summary(ticket, status:, from_assignment_version: nil, missing_reason: nil, fields: SUMMARY,
                     trace_id: SecureRandom.hex(16))
    escalated = AuditEvent.where(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "ticket.escalated").order(:id).last
    from = from_assignment_version || escalated.data["from_assignment_version"]
    ms = ((Time.current - escalated.occurred_at) * 1000).round
    HandoffSummary.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: from, source: "platform",
                           status:, fields: status == "available" ? fields : nil, missing_reason:, trace_id:,
                           created_at: Time.current)
    data = { "source" => "platform", "from_assignment_version" => from, "ms_since_escalated" => ms }
    data["missing_reason"] = missing_reason if status == "missing"
    queue_audit(ticket, "handoff.summary_#{status}", trace_id, data)
  end

  private

  def record_transfer_notice(ticket, trace_id)
    last_customer = ticket.messages.where(direction: "inbound", author_type: "customer").order(:seq).last
    seq = ticket.messages.maximum(:seq).to_i + 1
    text = Handoff::Policy.for(ticket.brand).transfer_notice_text(ticket.brand.locale)
    message = Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "system", body: text,
                              seq:, channel: last_customer.channel, provider_account: last_customer.provider_account,
                              external_id: nil, trace_id:, received_at: Time.current)
    delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                provider_account: message.provider_account, kind: "handoff_notice", status: "pending", trace_id:)
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "delivery.requested",
                        dedup_key: "delivery:#{delivery.delivery_id}",
                        payload: { "delivery_id" => delivery.delivery_id, "ticket_id" => ticket.id, "seq" => seq },
                        trace_id:, next_attempt_at: Time.current)
    queue_audit(ticket, "delivery.requested", trace_id, "delivery_id" => delivery.delivery_id, "message_id" => message.id,
                                                        "seq" => seq, "kind" => "handoff_notice", "turn" => nil)
    ticket.bump_context_version!
    delivery
  end

  def record_agent_summary(ticket, from, fields, trace_id)
    HandoffSummary.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, from_assignment_version: from, source: "agent",
                           status: "available", fields:, trace_id:, created_at: Time.current)
    queue_audit(ticket, "handoff.summary_available", trace_id, "source" => "agent", "from_assignment_version" => from,
                                                               "ms_since_escalated" => 0)
    "available"
  end

  def record_summary_item(ticket, from, request)
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "handoff.summary",
                        dedup_key: "summary:#{ticket.id}:#{from}",
                        payload: { "ticket_id" => ticket.id, "from_assignment_version" => from, "reason" => request.data["reason"],
                                   "escalated_at" => Time.current.utc.iso8601(3) },
                        trace_id: request.trace_id, next_attempt_at: Time.current)
    "pending"
  end

  def queue_audit(ticket, event_type, trace_id, data)
    AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, data:,
                       trace_id:, occurred_at: Time.current)
  end
end

RSpec.configure { |c| c.include HumanQueueRecordHelpers }
