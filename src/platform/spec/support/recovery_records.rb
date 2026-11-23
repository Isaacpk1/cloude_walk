# Grava direto no banco, no formato combinado dos blocos 08 e 09 (common0809, itens 4 e 5), o que a
# recuperação (B2) e a DLQ da plataforma (B1) gravam, para testar o painel sem depender desses serviços:
# - record_outbox_recovered: auditoria outbox.recovered (item reoferecido, event_type e attempts);
# - record_outbox_closed_obsolete: item encerrado pela política de recuperação (completed_at, last_error) e a
#   auditoria outbox.closed_obsolete com o motivo;
# - seed_dead_letter: a linha de dead_letters e a auditoria dead_letter.recorded (mais dead_letter.audited no
#   desfecho audited), quando há atendimento correlacionado.
# As auditorias ligam-se ao item por outbox_event_id (e event_id, o mesmo valor) e levam occurred_at =
# Time.current, para os horários seguirem o tempo controlado do teste.
module RecoveryRecordHelpers
  def record_outbox_recovered(item)
    recovery_audit(item, "outbox.recovered", "event_type" => item.event_type, "attempts" => item.reload.attempts)
  end

  def record_outbox_closed_obsolete(item, reason: "turno_superseded")
    item.update_columns(completed_at: Time.current, lease_until: nil, last_error: reason)
    recovery_audit(item, "outbox.closed_obsolete", "event_type" => item.event_type, "attempts" => item.attempts,
                                                   "reason" => reason)
  end

  def seed_dead_letter(ticket: nil, brand: ticket&.brand, source: "broker", reason: "contrato", outcome: "escalated",
                         turn: nil, event_id: SecureRandom.uuid, payload: nil, headers: nil, violations: [ "/turn" ],
                         error: nil, trace_id: SecureRandom.hex(16), offset: nil)
    @dead_letter_offset = (@dead_letter_offset || 0) + 1
    payload ||= JSON.generate("event_id" => event_id, "turn" => turn&.turn)
    headers ||= { "event_id" => event_id, "dlq_reason" => reason, "dlq_source" => source,
                  "dlq_violations" => JSON.generate(violations) }
    dead_letter = DeadLetter.create!(
      brand:, ticket:, topic: "helpdesk.agent.dlq.v1", partition: 3, offset: offset || @dead_letter_offset, source:, reason:,
      event_id:, trace_id:, turn: turn&.turn, violations:, headers:, payload:, error:, attempts: 1, outcome:,
      created_at: Time.current
    )
    return dead_letter unless ticket

    data = { "dead_letter_id" => dead_letter.id, "source" => source, "reason" => reason, "outcome" => outcome,
             "event_id" => event_id, "turn" => turn&.turn }
    dead_letter_audit(dead_letter, "dead_letter.recorded", data)
    dead_letter_audit(dead_letter, "dead_letter.audited", data) if outcome == "audited"
    dead_letter
  end

  private

  def recovery_audit(item, event_type, data)
    AuditEvent.create!(brand_id: item.brand_id, ticket_id: item.ticket_id, actor_type: "system", event_type:,
                       trace_id: item.trace_id, occurred_at: Time.current,
                       data: { "outbox_event_id" => item.id, "event_id" => item.id }.merge(data))
  end

  def dead_letter_audit(dead_letter, event_type, data)
    AuditEvent.create!(brand_id: dead_letter.brand_id, ticket_id: dead_letter.ticket_id, actor_type: "system", event_type:,
                       trace_id: dead_letter.trace_id, occurred_at: Time.current, data:)
  end
end

RSpec.configure { |c| c.include RecoveryRecordHelpers }
