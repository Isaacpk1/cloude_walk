# Lê a triagem e o roteamento do atendimento para a conversa (ROADMAP 11 Frontend; RF-10, RF-12, RF-15, RF-18, RF-24,
# RF-54, RN-11 a RN-16, RN-20, RN-28), das colunas do ticket e da auditoria no formato combinado do bloco 11:
# triage.classified, routing.decided, ticket.assigned e triage.skipped. Repetição: vale o registro mais recente de
# cada tipo (a linha do tempo mostra todos). Isolamento por marca (invariante 6): auditoria e filas filtradas pelo
# brand_id do atendimento; fila de outra marca não tem o nome revelado.
class TriagePhase
  AUDITS = %w[triage.classified routing.decided ticket.assigned triage.skipped].freeze
  ASSIGN_REASONS = %w[ia_primeiro fila_sem_ia categoria_somente_humana].freeze

  def initialize(ticket)
    @ticket = ticket
  end

  # nil enquanto não há triagem nem decisão gravada.
  def view
    classified = last("triage.classified")
    routed = last("routing.decided")
    assigned = audits.reverse.find { _1.event_type == "ticket.assigned" && ASSIGN_REASONS.include?(_1.data["reason"]) }
    skipped = classified ? nil : last("triage.skipped")
    return if [ classified, routed, assigned, skipped ].none? && @ticket.category.nil?

    data = classified&.data || {}
    ConversationView::Triage.new(
      category: @ticket.category || data["category"], priority: @ticket.priority || data["priority"],
      tags: @ticket.tags.presence || data["tags"], matched: data["matched"], unclassified: data["unclassified"] == true,
      classified_seq: data["seq"], classified_at: classified&.occurred_at, routing: routed && self.class.routing(routed, queues),
      assignment: assigned && assignment(assigned), skipped: skipped && skip(skipped), trace_id: (classified || routed)&.trace_id
    )
  end

  # Também usada pela linha do tempo (TriageEvents). `queues`: id → nome da versão atual, só da marca do caso.
  def self.routing(audit, queues)
    data = audit.data
    ConversationView::Routing.new(
      queue_id: data["queue_id"], queue_name: data["queue_name"] || queues[data["queue_id"]],
      queue_version: data["queue_version"], ruleset_version: audit.ruleset_version || data["ruleset_version"],
      rule_index: data["rule_index"], rule_name: data["rule_name"], group_index: data["group_index"],
      conditions: data["conditions"], default: data["default"] == true,
      skipped_rules: Array(data["skipped_rules"]).map { skipped_rule(_1, queues) },
      decided_at: audit.occurred_at, trace_id: audit.trace_id
    )
  end

  def self.skipped_rule(rule, queues)
    rule = { "rule_index" => rule } unless rule.is_a?(Hash)
    id = rule["queue_id"]
    ConversationView::Routing::SkippedRule.new(rule_index: rule["rule_index"], rule_name: rule["rule_name"],
                                               queue_name: queues[id] || rule["queue_name"] || "##{id}",
                                               reason: rule["reason"] || "fila_inativa")
  end

  def self.queue_names(brand_id)
    HelpdeskQueue.joins(:current_version).where(brand_id:).pluck(:id, "queue_versions.name").to_h
  end

  def self.assignment(audit, queues)
    data = audit.data
    ConversationView::Triage::Assignment.new(to: data["to"], reason: data["reason"], queue_name: queues[data["queue_id"]],
                                             state_from: data["state_from"], state_to: data["state_to"],
                                             assigned_at: audit.occurred_at)
  end

  def self.skip(audit)
    ConversationView::Triage::Skip.new(reason: audit.data["reason"], state: audit.data["state"], skipped_at: audit.occurred_at)
  end

  private

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: AUDITS).order(:occurred_at, :id).to_a
  end

  def last(type) = audits.reverse.find { _1.event_type == type }
  def queues = @queues ||= self.class.queue_names(@ticket.brand_id)
  def assignment(audit) = self.class.assignment(audit, queues)
  def skip(audit) = self.class.skip(audit)
end
