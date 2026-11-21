# Grava direto no banco um turno no formato combinado do bloco 06 (07, seção 3.4; RN-49, RN-55), para
# testar o painel sem depender do Turns::Open das outras subtarefas: ai_turns com context_version e
# context_digest, e a auditoria ai_turn.opened com pending_seqs, history_seqs, window_ms, channel,
# pending_chars, context_chars, context_version e context_digest. O contexto é montado como o do
# Turns::Open: pendentes = mensagens do cliente depois da última saída visível; histórico = o que veio antes.
# `ai_turn.not_opened` com motivo contexto_excede_limite grava o mesmo que o Turns::Open real (recusa terminal):
# zera dispatch_due_at, mantém o ciclo (first_pending_*, ai_deadline_at) e audita dispatch_id, cover_until_seq,
# pending_seqs, pending_chars e limit. O caminho real está em spec/requests/turn_refusal_panel_spec.rb.
module TurnContextRecordHelpers
  def ingest_on(channel, text = "meu repasse não caiu", brand: "infinitepay", identity: "cliente@example.test", **)
    message = normalized_message(text:, brand:, identity:, **)
              .merge("channel" => channel, "provider_account" => "#{brand}-#{channel}-mock")
    Ingestion::Receive.call(message, provider_payload: {})
  end

  # digest: :computed (padrão), nil (turno anterior ao bloco 06) ou uma string qualquer.
  def record_turn_06(ticket, context_version: 1, digest: :computed, window_ms: nil, dispatch_due_at: nil,
                     trace_id: SecureRandom.hex(16))
    ticket.reload
    pending, history = pending_and_history(ticket)
    context = { "pending_messages" => pending.map { { "seq" => _1.seq, "text" => _1.body } },
                "history" => history.map { { "seq" => _1.seq, "author" => _1.author_type, "text" => _1.body } } }
    policy = Turns::Policy.for(ticket.brand)
    due = dispatch_due_at || ticket.dispatch_due_at || Time.current
    event_id = SecureRandom.uuid
    number = ticket.ai_turns.maximum(:turn).to_i + 1
    context_digest = digest == :computed ? Turns::ContextDigest.call(context) : digest
    turn = ticket.ai_turns.create!(
      brand_id: ticket.brand_id, turn: number, context_until_seq: ticket.latest_customer_seq,
      assignment_version: ticket.assignment_version, context:, event_id:, status: "eligible",
      deadline_at: Time.current + policy.turn_deadline, context_version:, context_digest:
    )
    ticket.update_columns(dispatch_due_at: nil)
    texts = context.values.flatten.sum { _1["text"].length }
    AuditEvent.create!(
      brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type: "ai_turn.opened", trace_id:,
      data: { turn: number, event_id:, context_until_seq: turn.context_until_seq, pending_seqs: pending.map(&:seq),
              history_seqs: history.map(&:seq), channel: ticket.channel,
              window_ms: window_ms || (policy.window_for(ticket.channel) * 1000).to_i,
              pending_chars: pending.sum { _1.body.length }, context_chars: texts, context_version:, context_digest:,
              dispatch_due_at: due.utc.iso8601(3), deadline_at: turn.deadline_at.utc.iso8601(3) }
    )
    turn
  end

  def record_context_too_large(ticket, pending_chars:, limit: 16_000, trace_id: SecureRandom.hex(16))
    ticket.reload
    pending, = pending_and_history(ticket)
    ticket.update_columns(dispatch_due_at: nil)
    AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type: "ai_turn.not_opened",
                       trace_id:, data: { dispatch_id: SecureRandom.uuid, reason: "contexto_excede_limite", pending_chars:, limit:,
                                          pending_seqs: pending.map(&:seq), cover_until_seq: ticket.latest_customer_seq })
  end

  private

  def pending_and_history(ticket)
    answered_until = ticket.messages.where(direction: "outbound", internal: false).maximum(:seq).to_i
    pending = ticket.messages.where(direction: "inbound", author_type: "customer").where(seq: (answered_until + 1)..).order(:seq).to_a
    first = pending.first&.seq || (ticket.latest_customer_seq + 1)
    [ pending, ticket.messages.where(internal: false).where(seq: ...first).order(:seq).to_a ]
  end
end

RSpec.configure { |c| c.include TurnContextRecordHelpers }
