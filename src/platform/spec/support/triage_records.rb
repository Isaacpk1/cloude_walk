# Grava direto no banco, no formato da interface combinada do bloco 11 (/home/claude/tools/common11.md, "Contratos
# entre os agentes"), o que a triagem (G1, Triage::Run) e o roteamento (G2, Routing::Evaluate) gravam, para testar o
# painel sem depender desses serviços:
# - record_triage_classified: a auditoria triage.classified (RN-11 a RN-13), com as colunas do ticket;
# - record_routing_decided: a auditoria routing.decided (RF-15, RF-18, RN-16, RN-20), com ruleset_version também na
#   coluna da auditoria, e a fila e as versões no ticket;
# - record_ticket_assigned: a auditoria ticket.assigned (RF-24, RN-28) e o estado do ticket;
# - record_triage_skipped: a auditoria triage.skipped com o motivo.
# As auditorias levam occurred_at = Time.current, para seguir o tempo controlado do teste.
module TriageRecordHelpers
  # Uma fila da marca com uma versão publicada (nome e IA primeiro).
  def routing_queue_for(brand, name:, ai_first: true, escalation: false, active: true)
    queue = create(:queue_record, team: create(:team, brand:), escalation:, active:)
    queue.publish_version!(name:, created_by: nil, ai_first:)
    queue.reload
  end

  def record_triage_classified(ticket, category:, priority:, tags: [], matched: [], unclassified: false, seq: 1,
                               trace_id: SecureRandom.hex(16))
    ticket.reload.update_columns(category:, priority:, tags:)
    triage_audit(ticket, "triage.classified", trace_id, "category" => category, "priority" => priority, "tags" => tags,
                                                        "matched" => matched, "unclassified" => unclassified, "seq" => seq)
  end

  # `conditions`: as condições do grupo que casou, no formato do ADR-003. `skipped_rules`: as regras puladas por fila
  # inativa (RN-15), cada uma com rule_index, rule_name, queue_id e reason.
  def record_routing_decided(ticket, queue:, ruleset_version:, rule_index: nil, rule_name: nil, group_index: nil,
                             conditions: [], default: rule_index.nil?, skipped_rules: [], trace_id: SecureRandom.hex(16))
    version = queue&.current_version
    ticket.reload.update_columns(queue_id: queue&.id, queue_version: version&.version, ruleset_version:)
    triage_audit(ticket, "routing.decided", trace_id, {
                   "moment" => "criacao", "queue_id" => queue&.id, "queue_version" => version&.version,
                   "queue_name" => version&.name, "ruleset_version" => ruleset_version, "rule_index" => rule_index,
                   "rule_name" => rule_name, "group_index" => group_index, "conditions" => conditions,
                   "default" => default, "skipped_rules" => skipped_rules
                 })
  end

  def record_ticket_assigned(ticket, to:, reason:, queue:, assignee: nil, trace_id: SecureRandom.hex(16))
    ticket.reload
    state_to = to == "ia" ? "com_ia" : "aguardando_humano"
    data = { "to" => to, "reason" => reason, "queue_id" => queue&.id, "assignee_id" => assignee&.id,
             "state_from" => ticket.state, "state_to" => state_to }
    ticket.update_columns(state: state_to, assignee_id: assignee&.id, queue_id: queue&.id || ticket.queue_id,
                          queue_version: queue&.current_version&.version || ticket.queue_version)
    triage_audit(ticket, "ticket.assigned", trace_id, data)
  end

  def record_triage_skipped(ticket, reason:, trace_id: SecureRandom.hex(16))
    triage_audit(ticket, "triage.skipped", trace_id, "reason" => reason, "state" => ticket.reload.state)
  end

  private

  # routing.decided leva a versão do conjunto também na coluna audit_events.ruleset_version (RN-54).
  def triage_audit(ticket, event_type, trace_id, data)
    AuditEvent.create!(brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type:, data:,
                       trace_id:, ruleset_version: data["ruleset_version"], occurred_at: Time.current)
  end
end

RSpec.configure { |c| c.include TriageRecordHelpers }
