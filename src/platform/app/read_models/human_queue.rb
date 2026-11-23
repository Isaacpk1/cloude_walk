# Fila humana do painel (ROADMAP 10, Frontend; RF-42, RF-45, RN-29; 07, seção 3.2): os casos em `aguardando_humano`,
# lidos de tickets e da auditoria no formato combinado do bloco 10 (ticket.escalated, ticket.priority_raised,
# handoff.summary_*) e de handoff_summaries.
#
# Ordem (RN-29): prioridade (crítica, alta, média, baixa; sem triagem vale média, RN-13), depois o mais antigo na
# fila (o ticket.escalated mais novo do caso). O SLA entra na ordem com o bloco 13. Cada caso é uma linha só, mesmo
# com vários ticket.escalated: a linha vem do ticket, e o tempo, do último.
#
# Marca (invariante 6): como o resto do painel, sem perfil ainda mostra todas as marcas, com a marca em cada linha;
# com `brand_slug`, só aquela marca, e marca desconhecida é NotFound (404). Toda leitura auxiliar filtra pelo
# brand_id de cada caso.
#
# Tempo real: `streams` diz em quais streams do Turbo a página escuta. O AuditEvent avisa esses streams depois do
# commit (só um pedido de recarga, sem dado do caso no stream).
class HumanQueue
  NotFound = Class.new(StandardError)
  LIMIT = 200
  STATE = "aguardando_humano".freeze
  STREAM = :human_queue
  PRIORITY_ORDER = <<~SQL.squish.freeze
    CASE tickets.priority WHEN 'critica' THEN 0 WHEN 'alta' THEN 1 WHEN 'baixa' THEN 3 ELSE 2 END
  SQL
  # A entrada mais nova do caso na fila humana, na marca do caso (invariante 6): o ticket.escalated do handoff ou o
  # ticket.assigned da triagem para a fila humana (bloco 11: fila sem IA ou categoria somente humana).
  LAST_ESCALATION = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT a.id, a.occurred_at FROM audit_events a
      WHERE a.brand_id = tickets.brand_id AND a.ticket_id = tickets.id
        AND (a.event_type = 'ticket.escalated' OR (a.event_type = 'ticket.assigned' AND a.data->>'to' = 'fila_humana'))
      ORDER BY a.id DESC LIMIT 1
    ) escalation ON true
  SQL

  attr_reader :brand

  def initialize(brand_slug: nil)
    @brand = brand_slug.presence && (Brand.find_by(slug: brand_slug) || raise(NotFound, "marca #{brand_slug} não encontrada"))
  end

  # Streams do Turbo da página: o da marca com ?marca=, o geral sem ela.
  def streams = brand ? [ STREAM, brand ] : [ STREAM ]

  # Os streams que uma auditoria do caso avisa: o geral e o da marca.
  def self.streams_for(brand) = [ [ STREAM ], [ STREAM, brand ] ]

  def entries
    tickets = scope.to_a
    return [] if tickets.empty?

    audits = audits_for(tickets)
    summaries = summaries_for(tickets, audits)
    versions = queue_versions_for(tickets)
    @titles = titles_for(tickets)
    tickets.map { entry(_1, audits.fetch(_1.id, []), summaries, versions) }
  end

  private

  def scope
    records = Ticket.includes(:brand, :customer).joins(LAST_ESCALATION).where(state: STATE)
    records = records.where(brand_id: brand.id) if brand
    records.select("tickets.*", "escalation.id AS escalation_audit_id")
           .order(Arel.sql("#{PRIORITY_ORDER}, COALESCE(escalation.occurred_at, tickets.updated_at), tickets.id"))
           .limit(LIMIT)
  end

  AUDITS = %w[ticket.escalated ticket.assigned ticket.priority_raised handoff.summary_available handoff.summary_missing].freeze

  def audits_for(tickets)
    pairs = tickets.map { [ _1.brand_id, _1.id ] }
    AuditEvent.where(event_type: AUDITS).where([ :brand_id, :ticket_id ] => pairs).order(:id).group_by(&:ticket_id)
  end

  def summaries_for(tickets, audits)
    keys = tickets.filter_map do |ticket|
      escalated = last_of(audits.fetch(ticket.id, []), "ticket.escalated")
      escalated && [ ticket.brand_id, ticket.id, escalated.data["from_assignment_version"] ]
    end
    return {} if keys.empty?

    HandoffSummary.where([ :brand_id, :ticket_id, :from_assignment_version ] => keys).index_by(&:ticket_id)
  end

  def queue_versions_for(tickets)
    pairs = tickets.select(&:queue_id).map { [ _1.brand_id, _1.queue_id ] }.uniq
    return {} if pairs.empty?

    QueueVersion.joins(:queue).where(queue_id: pairs.map(&:last), queues: { brand_id: pairs.map(&:first) })
                .select("queue_versions.*", "queues.brand_id AS queue_brand_id", "queues.escalation AS queue_escalation",
                        "queues.is_default AS queue_default")
                .index_by { [ _1.queue_brand_id, _1.queue_id, _1.version ] }
  end

  def last_of(audits, type) = audits.reverse.find { _1.event_type == type }

  def entry(ticket, audits, summaries, versions)
    escalated = audits.find { _1.id == ticket.escalation_audit_id }
    data = escalated&.data || {}
    data = data.merge("source" => "triagem") if escalated&.event_type == "ticket.assigned"
    raised = HandoffPhase.priority_raised(audits, escalated)
    version = versions[[ ticket.brand_id, ticket.queue_id, ticket.queue_version ]]
    HumanQueue::Entry.new(
      ticket_id: ticket.id, brand_slug: ticket.brand.slug, brand_name: ticket.brand.name,
      customer_name: ticket.customer.display_name, title: ticket_title(ticket), state: ticket.state,
      queue_id: version && ticket.queue_id, queue_name: version&.name, queue_version: version&.version,
      queue_kind: data["queue_kind"] || queue_kind(version), reason: data["reason"], source: data["source"],
      priority: ticket.priority, priority_from: raised&.data&.dig("from"), priority_to: raised&.data&.dig("to"),
      escalated_at: escalated&.occurred_at || ticket.updated_at,
      summary: summary(summaries[ticket.id], audits, data["from_assignment_version"]), trace_id: escalated&.trace_id,
      category: ticket.category
    )
  end

  def summary(record, audits, from_version)
    audit = record && audits.reverse.find do
      _1.event_type == "handoff.summary_#{record.status}" && _1.data["from_assignment_version"] == from_version
    end
    ConversationView::HandoffSummary.from(record, audit)
  end

  # Registros do bloco 08 (sem queue_kind no ticket.escalated): o tipo vem da própria fila.
  def queue_kind(version)
    return unless version
    return "escalation" if version.queue_escalation

    "default" if version.queue_default
  end

  # A primeira mensagem de cada caso, numa consulta só.
  def titles_for(tickets)
    Message.where([ :brand_id, :ticket_id ] => tickets.map { [ _1.brand_id, _1.id ] })
           .select("DISTINCT ON (ticket_id) ticket_id, body").order(:ticket_id, :seq)
           .to_h { [ _1.ticket_id, _1.body.to_s.truncate(60) ] }
  end

  def ticket_title(ticket) = @titles.fetch(ticket.id, "")
end
