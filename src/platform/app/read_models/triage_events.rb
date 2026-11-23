# Triagem e roteamento do bloco 11 na linha do tempo (ROADMAP 11; RF-12, RF-15, RF-18, RF-24, RF-54, RN-11 a RN-16,
# RN-20, RN-28), lidos da auditoria no formato combinado do bloco 11. O routing.decided mostra a regra e a versão do
# conjunto que colocaram o caso na fila (critério "RF-18 + RF-54" do docs/04). Todos os registros aparecem, inclusive
# repetidos: a conversa mostra só o mais recente. Isolamento por marca (invariante 6).
class TriageEvents
  KINDS = { "triage.classified" => :triage_classified, "routing.decided" => :routing_decided,
            "ticket.assigned" => :triage_assigned, "triage.skipped" => :triage_skipped }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def events = audits.map { event_for(_1) }

  private

  def audits
    AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: KINDS.keys).order(:occurred_at, :id)
              .select { _1.event_type != "ticket.assigned" || TriagePhase::ASSIGN_REASONS.include?(_1.data["reason"]) }
  end

  def queues = @queues ||= TriagePhase.queue_names(@ticket.brand_id)

  def event_for(audit)
    kind = KINDS.fetch(audit.event_type)
    detail = case kind
    when :triage_classified then classified_detail(audit.data)
    when :routing_decided then routing_detail(TriagePhase.routing(audit, queues))
    when :triage_assigned then assigned_detail(TriagePhase.assignment(audit, queues))
    else TriagePhase.skip(audit).label
    end
    TimelineView::Event.new(kind:, started_at: audit.occurred_at, finished_at: audit.occurred_at, ticket_id: @ticket.id.to_s,
                            seq: kind == :triage_classified ? audit.data["seq"] : nil, turn: nil, trace_id: audit.trace_id,
                            source: DataSource::SYSTEM, detail:)
  end

  def classified_detail(data)
    triage = ConversationView::Triage.new(category: data["category"], priority: data["priority"], tags: data["tags"],
                                          matched: data["matched"], unclassified: data["unclassified"] == true,
                                          classified_seq: data["seq"], classified_at: nil, routing: nil, assignment: nil,
                                          skipped: nil, trace_id: nil)
    words = triage.matched.any? ? "palavras que decidiram: #{triage.matched.join(', ')}" : "nenhuma palavra-chave"
    if triage.unclassified
      "#{triage.unclassified_label}; #{words}"
    else
      tags = triage.tags.any? ? ", tags #{triage.tags.join(', ')}" : ", sem tags"
      "Categoria #{triage.category_label}, prioridade #{triage.priority_label}#{tags}; #{words} (RN-11, RN-12)"
    end
  end

  def routing_detail(routing)
    [ "Na criação: #{routing.explanation}", *routing.skipped_rule_labels ].join(" · ")
  end

  def assigned_detail(assignment) = "#{assignment.label} · estado #{assignment.state_from} → #{assignment.state_to}"
end
