# Uma linha da fila humana (ROADMAP 10; RF-42, RF-45, RN-29, RN-39 a RN-41). `escalated_at`: o ticket.escalated da
# atribuição atual (início da espera na fila). `priority_from`/`priority_to`: a subida da RN-41 gravada em
# ticket.priority_raised nesta escalação, ou nil. `summary`: ConversationView::HandoffSummary. Tudo texto comum.
class HumanQueue::Entry < Data.define(:ticket_id, :brand_slug, :brand_name, :customer_name, :title, :state, :queue_id,
                                      :queue_name, :queue_version, :queue_kind, :reason, :source, :priority,
                                      :priority_from, :priority_to, :escalated_at, :summary, :trace_id)
  QUEUE_KINDS = {
    "escalation" => "fila de escalas",
    "default" => "fila padrão: a marca não tem fila de escalas"
  }.freeze
  NO_QUEUE = "Sem fila: a marca não tem fila de escalas nem padrão".freeze

  def reason_label = ConversationView::Handoff.reason_label(reason)
  def source_label = ConversationView::Handoff.source_label(source)
  def priority_label = ConversationView::Priority.label(priority)
  def priority_raise_label = priority_to && ConversationView::Priority.raise_label(priority_from, priority_to)

  def queue_label
    return NO_QUEUE if queue_name.nil?

    kind = QUEUE_KINDS[queue_kind]
    "#{queue_name} · versão #{queue_version}#{" (#{kind})" if kind}"
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
