# Handoff do bloco 10 na linha do tempo (ROADMAP 10; RN-34, RN-39 a RN-41, RNF-06), lido da auditoria no formato
# combinado do bloco 10:
# - customer.human_requested (ingestão, RN-34): o pedido explícito de humano e o desfecho (pedido gravado, já havia
#   pedido nesta atribuição, ou caso já humano: só registrado);
# - ticket.priority_raised (Escalate, RN-41): de onde para onde e o motivo;
# - handoff.summary_available / _missing (RN-39, RN-40): a duração é ms_since_escalated, da escalação ao resumo.
# A entrega do aviso de transferência (handoff_notice) já vem do DeliveryEvents. Isolamento por marca (invariante 6).
class HandoffEvents
  AUDITS = %w[customer.human_requested ticket.priority_raised handoff.summary_available handoff.summary_missing].freeze

  OUTCOMES = {
    "handoff_pedido" => "pedido de handoff gravado",
    "handoff_ja_pedido" => "já havia um pedido de handoff nesta atribuição",
    "registrado" => "só registrado"
  }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def events = audits.map { event_for(_1) }

  private

  def audits
    AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: AUDITS).order(:occurred_at, :id)
  end

  def event_for(audit)
    data = audit.data
    case audit.event_type
    when "customer.human_requested" then build(audit, :human_requested, seq: data["seq"], detail: human_requested_detail(data))
    when "ticket.priority_raised"
      build(audit, :priority_raised, detail: "Prioridade #{ConversationView::Priority.short_label(data['from'])} → " \
                                             "#{ConversationView::Priority.short_label(data['to'])} na escalação: " \
                                             "#{ConversationView::Handoff.reason_label(data['reason'])} (RN-41)")
    else summary(audit, data)
    end
  end

  def human_requested_detail(data)
    outcome = OUTCOMES.fetch(data["outcome"], data["outcome"])
    outcome += " (item #{data['outbox_event_id']} no outbox)" if data["outbox_event_id"] && data["outcome"] == "handoff_pedido"
    outcome = "caso já com humano (#{data['state']}): #{outcome}" if data["outcome"] == "registrado"
    "Mensagem seq #{data['seq']} pede um humano (RN-34), estado #{data['state']}: #{outcome}"
  end

  def summary(audit, data)
    ms = data["ms_since_escalated"]
    started_at = ms ? audit.occurred_at - Rational(ms.to_i, 1000) : audit.occurred_at
    if audit.event_type == "handoff.summary_available"
      source = ConversationView::HandoffSummary::SOURCE_LABELS.fetch(data["source"], data["source"])
      build(audit, :summary_available, started_at:,
                                       detail: "Resumo de cinco campos #{source} (RN-39), escalação da atribuição " \
                                               "#{data['from_assignment_version']}; #{ms} ms depois da escalação (RNF-06)")
    else
      reason = ConversationView::HandoffSummary.missing_reason_label(data["missing_reason"])
      build(audit, :summary_missing, started_at:,
                                     detail: "Sem resumo: #{reason}; o caso já estava na fila com o histórico (RN-40), " \
                                             "#{ms} ms depois da escalação")
    end
  end

  def build(audit, kind, detail:, seq: nil, started_at: audit.occurred_at)
    TimelineView::Event.new(kind:, started_at: [ started_at, audit.occurred_at ].min, finished_at: audit.occurred_at,
                            ticket_id: @ticket.id.to_s, seq:, turn: nil, trace_id: audit.trace_id, source: DataSource::SYSTEM,
                            detail:)
  end
end
