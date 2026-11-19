# Fonte dos registros reais para as telas de conversa e linha do tempo (ROADMAP 02).
# Lê tickets, messages e outbox_events (07, seção 4) e devolve os mesmos ConversationView e
# TimelineView dos exemplos, marcados como DataSource::SYSTEM. Turnos, entregas e escalações
# entram aqui quando suas tabelas existirem (blocos 04 a 10).
class RecordedConversations
  LIMIT = 50
  WAITING = ConversationView::Participant.new(name: "Aguardando triagem", kind: "queue")

  def all = scope.order(id: :desc).limit(LIMIT).map { conversation(_1) }

  def find(id)
    ticket = ticket_for(id)
    ticket && conversation(ticket)
  end

  def timeline(id)
    ticket = ticket_for(id)
    return unless ticket

    outbox = OutboxEvent.where(ticket:, event_type: "message.received").index_by { _1.payload["message_id"] }
    events = ticket.messages.select { _1.direction == "inbound" }.flat_map { message_events(ticket, _1, outbox[_1.id]) }
    TimelineView.new(conversation_id: ticket.id.to_s, ticket_id: ticket.id.to_s, events:, source: DataSource::SYSTEM)
  end

  private

  def scope = Ticket.includes(:brand, :customer, :messages)

  def ticket_for(id)
    return unless id.to_s.match?(/\A\d+\z/)

    scope.find_by(id: id.to_i)
  end

  def conversation(ticket)
    ConversationView.new(
      id: ticket.id.to_s, ticket_id: ticket.id.to_s, brand_slug: ticket.brand.slug, brand_name: ticket.brand.name,
      customer_name: ticket.customer.display_name, channel: ticket.channel, state: ticket.state,
      title: ticket.messages.first&.body.to_s.truncate(60), assignee: WAITING,
      assignment_version: ticket.assignment_version, latest_customer_seq: ticket.latest_customer_seq,
      messages: ticket.messages.map { message(ticket, _1) }, turns: [], escalations: [], source: DataSource::SYSTEM
    )
  end

  def message(ticket, record)
    ConversationView::Message.new(
      seq: record.seq, author_type: record.author_type, author_name: author_name(ticket, record), body: record.body,
      direction: record.direction, internal: record.internal, occurred_at: record.received_at,
      trace_id: record.trace_id, delivery_status: nil, delivery_id: nil
    )
  end

  def author_name(ticket, record) = record.author_type == "customer" ? ticket.customer.display_name : record.author_type

  # Recebimento: da chegada do webhook até a linha da mensagem. Gravação: da mensagem ao último
  # registro da mesma transação (o outbox). O 202 só sai depois do commit (invariante 1).
  def message_events(ticket, record, outbox_item)
    common = { ticket_id: ticket.id.to_s, seq: record.seq, turn: nil, trace_id: record.trace_id, source: DataSource::SYSTEM }
    persisted_until = [ outbox_item&.created_at, record.created_at ].compact.max
    [
      TimelineView::Event.new(kind: :received, started_at: record.received_at, finished_at: [ record.created_at, record.received_at ].max,
                              detail: "Webhook #{record.channel} da conta #{record.provider_account} (#{record.external_id})", **common),
      TimelineView::Event.new(kind: :persisted, started_at: record.created_at, finished_at: persisted_until,
                              detail: "Mensagem seq #{record.seq}, auditoria e outbox na mesma transação", **common)
    ]
  end
end
