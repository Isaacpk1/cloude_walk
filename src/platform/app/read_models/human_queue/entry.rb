# Uma linha da fila humana (ROADMAP 10; RF-42, RF-45, RN-29, RN-39 a RN-41). `escalated_at`: o ticket.escalated da
# atribuição atual (início da espera na fila). `priority_from`/`priority_to`: a subida da RN-41 gravada em
# ticket.priority_raised nesta escalação, ou nil. `summary`: ConversationView::HandoffSummary. `category`: a categoria
# da triagem (bloco 11), ou nil. Tudo texto comum.
class HumanQueue::Entry < Data.define(:ticket_id, :brand_slug, :brand_name, :customer_name, :title, :state, :queue_id,
                                      :queue_name, :queue_version, :queue_kind, :reason, :source, :priority,
                                      :priority_from, :priority_to, :escalated_at, :summary, :trace_id,
                                      :category)
  QUEUE_KINDS = {
    "escalation" => "fila de escalas",
    "default" => "fila padrão: a marca não tem fila de escalas"
  }.freeze
  NO_QUEUE = "Sem fila: a marca não tem fila de escalas nem padrão".freeze

  def reason_label = ConversationView::Handoff.reason_label(reason)
  def source_label = ConversationView::Handoff.source_label(source)
  def priority_label = ConversationView::Priority.label(priority)
  # Bloco 11 (RF-10, RN-11): a categoria da triagem; caso escalado antes da triagem aparece como "sem triagem".
  def category_label = ConversationView::Category.label(category) || "sem triagem"
  def priority_raise_label = priority_to && ConversationView::Priority.raise_label(priority_from, priority_to)

  def queue_label = self.class.queue_label(queue_name, queue_version, queue_kind)

  def self.queue_label(name, version, kind)
    return NO_QUEUE if name.nil?

    kind_label = QUEUE_KINDS[kind]
    "#{name}#{" · versão #{version}" if version}#{" (#{kind_label})" if kind_label}"
  end

  def waiting_ms(now = Time.current) = TimelineView::Event.ms_between(escalated_at, now)
  def waiting_text(now = Time.current) = self.class.duration_text(waiting_ms(now))

  def self.duration_text(ms)
    seconds = [ ms, 0 ].max / 1000
    hours, rest = seconds.divmod(3600)
    minutes, secs = rest.divmod(60)
    return "#{hours} h #{minutes} min" if hours.positive?
    return "#{minutes} min #{secs} s" if minutes.positive?

    "#{secs} s"
  end
end
