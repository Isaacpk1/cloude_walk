# Etapa de publicação da linha do tempo (ROADMAP 03), lida de ai_turns, do outbox e da auditoria de
# cada tentativa (Outbox::Publish). A publicação vai da abertura do turno à confirmação do Kafka.
# Cada tentativa que falhou ou foi cancelada vira um evento com a origem do erro.
class PublicationEvents
  OUTCOMES = %w[agent_event.published agent_event.publish_failed agent_event.rejected agent_event.discarded].freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def events
    turns = @ticket.ai_turns.to_a
    return [] if turns.empty?

    outbox = OutboxEvent.where(id: turns.map(&:event_id)).index_by(&:id)
    audits = AuditEvent.where(ticket_id: @ticket.id, event_type: OUTCOMES).order(:occurred_at, :id)
                       .group_by { _1.data["event_id"] }
    turns.flat_map { turn_events(_1, outbox[_1.event_id], audits.fetch(_1.event_id, [])) }
  end

  private

  def turn_events(turn, item, audits)
    published = audits.find { _1.event_type == "agent_event.published" }
    [ publication(turn, item, published) ] + audits.reject { _1 == published }.map { failure(turn, item, _1) }
  end

  def publication(turn, item, published)
    # A auditoria usa o relógio do banco; o max evita fim antes do início se os relógios divergirem.
    finished_at = published && [ published.occurred_at, turn.created_at ].max
    event(turn, item, :published, started_at: turn.created_at, finished_at:,
                                  detail: publication_detail(turn, item, published))
  end

  def publication_detail(turn, item, published)
    head = "Turno #{turn.turn}, event_id #{turn.event_id[0, 8]}"
    return "#{head}: aguardando confirmação (tentativas: #{item&.attempts.to_i})" unless published

    data = published.data
    "#{head}: Kafka confirmou em #{data['topic']}, partição #{data['partition']}, offset #{data['offset']} " \
      "(tentativa #{data['attempt']}, #{data['broker_status']})"
  end

  # O erro de uma tentativa de publicação que falhou, foi recusada ou cancelada. Num lugar só: a linha do
  # tempo e o resumo das tentativas do item (OutboxAttempts) mostram o mesmo motivo.
  def self.error_for(audit)
    data = audit.data
    discarded = audit.event_type == "agent_event.discarded"
    TimelineView::Error.new(
      origin: discarded ? data["reason"] : data["origin"], http_status: data["http_status"],
      message: data["error"] || data["reason"], attempt: data["attempt"],
      retry: audit.event_type == "agent_event.publish_failed" && data["retry"] == true,
      next_attempt_at: data["next_attempt_at"] && Time.zone.parse(data["next_attempt_at"]), outcome: data["outcome"]
    )
  end

  def failure(turn, item, audit)
    data = audit.data
    discarded = audit.event_type == "agent_event.discarded"
    error = self.class.error_for(audit)
    event(turn, item, discarded ? :publish_discarded : :publish_failed, started_at: audit.occurred_at,
                                                                       finished_at: audit.occurred_at,
                                                                       detail: "Tentativa #{data['attempt']}: #{error.origin_label}", error:)
  end

  def event(turn, item, kind, **attrs)
    TimelineView::Event.new(kind:, ticket_id: @ticket.id.to_s, seq: turn.context_until_seq, turn: turn.turn,
                            trace_id: item&.trace_id, source: DataSource::SYSTEM, **attrs)
  end
end
