# Grava direto no banco, no formato da interface combinada dos blocos 08 e 09 (itens 1, 2 e 5), o que o scheduler,
# o worker do aviso de progresso (A2) e o handoff mínimo (A1) gravam, para testar o painel sem esses serviços:
# - record_progress_due / record_progress_scheduled / record_progress_sent / record_progress_discarded: o aviso de
#   progresso do ciclo (RN-57): progress_due_at, o registro do scheduler, a saída kind "progress" e o descarte;
# - record_delivery_cancelled: a entrega cancelada com o motivo (resposta_aplicada, handoff);
# - record_timeout_scheduled / record_turn_expired: o registro do prazo vencido pelo scheduler e o turno expirado;
# - record_handoff_requested / record_escalated / record_handoff_discarded: o pedido de handoff pelo outbox e o seu
#   desfecho (Handoff::Escalate): fila padrão, assignment_version + 1, ciclo encerrado, turnos e saídas cancelados.
# As auditorias levam occurred_at = Time.current, para as durações seguirem o tempo controlado do teste.
module HandoffRecordHelpers
  def default_queue_for(brand, name: "Atendimento geral")
    HelpdeskQueue.find_by(brand_id: brand.id, is_default: true) || begin
      queue = create(:queue_record, team: create(:team, brand:), is_default: true)
      queue.publish_version!(name:, created_by: nil)
      queue
    end
  end

  # A2: a ingestão grava progress_due_at = first_pending_at + 15 s quando abre o ciclo.
  def record_progress_due(ticket)
    ticket.reload.update_columns(progress_due_at: ticket.first_pending_at + 15.seconds)
    ticket
  end

  # A2: o Deadlines::ProgressDue registra a ação vencida no outbox e audita o registro.
  def record_progress_scheduled(ticket, trace_id: SecureRandom.hex(16))
    ticket.reload
    deadline = ticket.progress_due_at
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "progress.notice",
                        dedup_key: "progress:#{ticket.id}:#{ticket.first_pending_seq}",
                        payload: { "ticket_id" => ticket.id, "first_pending_seq" => ticket.first_pending_seq },
                        trace_id:, next_attempt_at: Time.current)
    audit(ticket, "progress.notice_scheduled", trace_id, "deadline_at" => deadline.utc.iso8601(3),
                                                         "delay_ms" => ms_since(deadline),
                                                         "first_pending_seq" => ticket.first_pending_seq)
  end

  # A2: o worker grava a saída do aviso (bot), a entrega kind "progress" do ciclo e o delivery.requested.
  def record_progress_sent(ticket, text: "Ainda estou verificando, já te respondo.", trace_id: SecureRandom.hex(16))
    ticket.reload
    last_customer = ticket.messages.where(direction: "inbound", author_type: "customer").order(:seq).last
    seq = ticket.messages.maximum(:seq).to_i + 1
    message = Message.create!(brand_id: ticket.brand_id, ticket:, direction: "outbound", author_type: "bot", body: text,
                              seq:, channel: last_customer.channel, provider_account: last_customer.provider_account,
                              external_id: nil, trace_id:, received_at: Time.current)
    delivery = Delivery.create!(brand_id: ticket.brand_id, ticket:, message:, seq:, channel: message.channel,
                                provider_account: message.provider_account, kind: "progress", status: "pending",
                                ai_assignment_version: ticket.assignment_version,
                                ai_first_pending_seq: ticket.first_pending_seq, trace_id:)
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "delivery.requested",
                        dedup_key: "delivery:#{delivery.delivery_id}",
                        payload: { "delivery_id" => delivery.delivery_id, "ticket_id" => ticket.id, "seq" => seq },
                        trace_id:, next_attempt_at: Time.current)
    audit(ticket, "delivery.requested", trace_id, "delivery_id" => delivery.delivery_id, "message_id" => message.id,
                                                  "seq" => seq, "kind" => "progress", "turn" => nil)
    audit(ticket, "progress.notice_sent", trace_id, "delivery_id" => delivery.delivery_id, "seq" => seq,
                                                    "first_pending_seq" => ticket.first_pending_seq)
    ticket.bump_context_version!
    ticket.update_columns(progress_due_at: nil)
    delivery
  end

  def record_progress_discarded(ticket, reason: "resposta_aplicada", trace_id: SecureRandom.hex(16))
    ticket.reload
    audit(ticket, "progress.notice_discarded", trace_id, "reason" => reason, "first_pending_seq" => ticket.first_pending_seq)
    ticket.update_columns(progress_due_at: nil) if ticket.first_pending_at
  end

  # O que a resposta aplicada faz no ciclo (AgentActions::Apply; item 2: zera também progress_due_at).
  def close_cycle(ticket)
    ticket.update_columns(first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil, ai_deadline_at: nil,
                          progress_due_at: nil)
  end

  def record_delivery_cancelled(delivery, reason:)
    delivery.update_columns(status: "cancelled", lease_until: nil)
    audit(delivery.ticket, "delivery.cancelled", delivery.trace_id, "delivery_id" => delivery.delivery_id,
                                                                    "seq" => delivery.seq, "reason" => reason)
  end

  # A1: o Deadlines::TurnTimeout / CycleTimeout registra o prazo vencido no outbox e audita com o atraso.
  def record_timeout_scheduled(ticket, scope:, turn: nil, trace_id: SecureRandom.hex(16))
    ticket.reload
    deadline = scope == :turn ? turn.deadline_at : ticket.ai_deadline_at
    key = scope == :turn ? "timeout:turn:#{ticket.id}:#{turn.turn}" : "timeout:cycle:#{ticket.id}:#{ticket.first_pending_seq}"
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "#{scope}.timeout", dedup_key: key,
                        payload: { "ticket_id" => ticket.id, "turn" => turn&.turn, "first_pending_seq" => ticket.first_pending_seq },
                        trace_id:, next_attempt_at: Time.current)
    audit(ticket, "#{scope}.timeout_scheduled", trace_id, "deadline_at" => deadline.utc.iso8601(3),
                                                          "delay_ms" => ms_since(deadline), "turn" => turn&.turn,
                                                          "first_pending_seq" => ticket.first_pending_seq)
  end

  # Formato do Deadlines::Expire#discard: o payload do item (turn, first_pending_seq, assignment_version, prazo) e o motivo.
  def record_timeout_discarded(ticket, scope:, reason:, turn: nil, trace_id: SecureRandom.hex(16))
    ticket.reload
    audit(ticket, "#{scope}.timeout_discarded", trace_id, "timeout" => "#{scope}.timeout", "reason" => reason,
                                                          "turn" => turn&.turn, "first_pending_seq" => ticket.first_pending_seq,
                                                          "assignment_version" => ticket.assignment_version)
  end

  def record_turn_expired(turn, trace_id: SecureRandom.hex(16))
    turn.update_columns(status: "expired")
    audit(turn.ticket, "ai_turn.expired", trace_id, "turn" => turn.turn, "deadline_at" => turn.deadline_at.utc.iso8601(3),
                                                    "event_id" => turn.event_id)
  end

  # Item 1: quem decide escalar grava o pedido no outbox e a auditoria com o mesmo data.
  def record_handoff_requested(ticket, reason:, source:, turn: nil, trace_id: SecureRandom.hex(16))
    ticket.reload
    data = { "ticket_id" => ticket.id, "reason" => reason, "source" => source, "turn" => turn&.turn,
             "first_pending_seq" => ticket.first_pending_seq, "assignment_version" => ticket.assignment_version }
    OutboxEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "handoff.requested",
                        dedup_key: "handoff:#{ticket.id}:#{ticket.assignment_version}", payload: data, trace_id:,
                        next_attempt_at: Time.current)
    audit(ticket, "handoff.requested", trace_id, data)
  end

  # Item 1: Handoff::Escalate (handoff mínimo do bloco 08), a partir da auditoria do pedido.
  def record_escalated(ticket, request)
    ticket.reload
    queue = default_queue_for(ticket.brand)
    from = ticket.assignment_version
    ticket.update_columns(state: "aguardando_humano", queue_id: queue.id, queue_version: queue.current_version.version,
                          assignment_version: from + 1, first_pending_seq: nil, first_pending_at: nil,
                          dispatch_due_at: nil, progress_due_at: nil, ai_deadline_at: nil)
    AiTurn.where(brand_id: ticket.brand_id, ticket_id: ticket.id, status: "eligible").update_all(status: "expired")
    Delivery.where(brand_id: ticket.brand_id, ticket_id: ticket.id, status: "pending", ai_assignment_version: from,
                   kind: %w[reply resolution progress]).find_each { record_delivery_cancelled(_1, reason: "handoff") }
    audit(ticket, "ticket.escalated", request.trace_id,
          "reason" => request.data["reason"], "source" => request.data["source"], "from_assignment_version" => from,
          "to_assignment_version" => from + 1, "queue_id" => queue.id)
  end

  def record_handoff_discarded(ticket, request, reason:)
    audit(ticket, "handoff.discarded", request.trace_id, request.data.merge("reason" => reason,
                                                                            "handoff_reason" => request.data["reason"]))
  end

  private

  def ms_since(time) = ((Time.current - time) * 1000).round

  def audit(ticket, event_type, trace_id, data)
    AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, data:,
                       trace_id:, occurred_at: Time.current)
  end
end

RSpec.configure { |c| c.include HandoffRecordHelpers }
