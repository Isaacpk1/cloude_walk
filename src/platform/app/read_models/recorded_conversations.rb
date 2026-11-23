# Fonte dos registros reais para as telas de conversa e linha do tempo (ROADMAP 02).
# Lê tickets, messages e outbox_events (07, seção 4) e devolve os mesmos ConversationView e
# TimelineView dos exemplos, marcados como DataSource::SYSTEM. A espera da janela de agrupamento
# (TurnWindowEvents), a abertura e a recusa do turno com o contexto (TurnContextEvents, bloco 06) e a publicação no broker (PublicationEvents) vêm de ai_turns e da auditoria (bloco 03).
# A ação recebida do agente (AgentActionEvents) vem de ai_turns.response e da auditoria (bloco 04).
# As mensagens de saída e a entrega ao canal (DeliveryEvents) vêm de deliveries e da auditoria
# delivery.* (bloco 05). Bloco 08: os prazos do ciclo e o aviso de progresso (DeadlinesPhase), o pedido de handoff e
# a fila humana (HandoffPhase, que também monta o histórico de escalação) e, na linha do tempo, os registros do
# scheduler, o turno expirado, o handoff e o aviso (DeadlineEvents). Atribuição a analista: bloco 10.
# delivery.* (bloco 05). As tentativas e o desfecho de cada item do outbox (OutboxAttempts) e o evento da DLQ
# (DeadLetterEvents) vêm do bloco 09. Escalações entram aqui quando suas tabelas existirem (bloco 10).
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
    events += TurnWindowEvents.new(ticket).events
    events += TurnContextEvents.new(ticket).events
    events += PublicationEvents.new(ticket).events
    events += TurnSupersededEvents.new(ticket).events
    events += AgentActionEvents.new(ticket).events
    events += DeliveryEvents.new(ticket).events
    events += DeadlineEvents.new(ticket).events
    events += HandoffEvents.new(ticket).events
    events += TriageEvents.new(ticket).events
    events += OutboxAttempts.new(ticket).events
    events += DeadLetterEvents.new(ticket).events
    TimelineView.new(conversation_id: ticket.id.to_s, ticket_id: ticket.id.to_s, events:, source: DataSource::SYSTEM)
  end

  private

  def scope = Ticket.includes(:brand, :customer, :messages)

  def ticket_for(id)
    return unless id.to_s.match?(/\A\d+\z/)

    scope.find_by(id: id.to_i)
  end

  def conversation(ticket)
    deliveries = DeliveryEvents.new(ticket)
    handoff = HandoffPhase.new(ticket, deliveries:)
    triage = TriagePhase.new(ticket).view
    ConversationView.new(
      id: ticket.id.to_s, ticket_id: ticket.id.to_s, brand_slug: ticket.brand.slug, brand_name: ticket.brand.name,
      customer_name: ticket.customer.display_name, channel: ticket.channel, state: ticket.state,
      title: ticket.messages.first&.body.to_s.truncate(60), assignee: assignee(ticket, handoff, triage),
      assignment_version: ticket.assignment_version, latest_customer_seq: ticket.latest_customer_seq,
      messages: ticket.messages.map { message(ticket, _1, deliveries) }, turns: turns(ticket, deliveries),
      escalations: handoff.escalations, source: DataSource::SYSTEM, deadlines: DeadlinesPhase.new(ticket).view,
      handoff: handoff.view, reconciliations: deliveries.reconciliations, triage:, **phase(ticket)
    )
  end

  # Depois do handoff (bloco 08) o caso espera na fila humana da marca; a atribuição a analista é do bloco 13.
  # Bloco 11: sem handoff, a atribuição da triagem diz se o caso está com a IA (RF-24) ou na fila humana (RN-28).
  def assignee(ticket, handoff, triage)
    queue = handoff.current_queue_name
    return ConversationView::Participant.new(name: queue, kind: "queue") if queue

    assignment = triage&.assignment
    return WAITING unless assignment
    return ConversationView::Participant.new(name: ticket.assignee&.name || "Agente de IA", kind: "bot") if assignment.to == "ia"

    ConversationView::Participant.new(name: assignment.queue_name || "fila sem nome", kind: "queue")
  end

  # A recusa terminal do turno da última mensagem substitui a fase de agrupamento (RN-49, RN-46).
  def phase(ticket)
    refusal = TurnRefusalPhase.new(ticket).view
    { turn_refusal: refusal, grouping: refusal ? nil : GroupingPhase.new(ticket).view }
  end

  def message(ticket, record, deliveries)
    delivery = deliveries.for_message(record)
    ConversationView::Message.new(
      seq: record.seq, author_type: record.author_type, author_name: author_name(ticket, record), body: record.body,
      direction: record.direction, internal: record.internal, occurred_at: record.received_at,
      trace_id: record.trace_id, delivery_status: delivery&.status, delivery_id: delivery&.delivery_id, delivery:
    )
  end

  TURN_NOTES = {
    "eligible" => "Publicado e aguardando a resposta do agente (bloco 04).",
    "superseded" => "Turno superado: uma mensagem nova do cliente chegou antes da resposta (RN-56).",
    "expired" => "Turno expirado: o prazo da IA venceu (RN-46).",
    "applied" => "Resposta aplicada."
  }.freeze

  def turns(ticket, deliveries)
    actions = AgentActionEvents.new(ticket)
    superseded = TurnSupersededEvents.new(ticket)
    first_received = ticket.messages.to_h { [ _1.seq, _1.received_at ] }
    records = ticket.ai_turns.where(brand_id: ticket.brand_id).order(:turn).to_a
    publications = OutboxEvent.where(brand_id: ticket.brand_id, id: records.map(&:event_id)).index_by(&:id)
    expirations = expiration_reasons(ticket)
    records.map do |record|
      agent_action = actions.for_turn(record)
      note = case record.status
      when "eligible" then publication_note(publications[record.event_id])
      when "expired" then expired_note(expirations[record.turn], publications[record.event_id])
      else TURN_NOTES[record.status]
      end
      turn(record, agent_action, stages(record, agent_action, actions, deliveries, first_received), note,
           superseded.for_turn(record.turn))
    end
  end

  # Bloco 08: o turno expira no pedido de handoff ou no timeout. A nota mostra a causa gravada em ai_turn.expired.
  def expiration_reasons(ticket)
    AuditEvent.where(brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: "ai_turn.expired")
              .order(:id).to_h { [ _1.data["turn"], _1.data["reason"] ] }
  end

  def expired_note(reason, publication)
    case reason
    when "publicacao_falhou"
      "Turno expirado: a publicação para o agente falhou sem nova tentativa (#{publication&.last_error || 'recusa'}) e o caso vai para um humano (RN-46)."
    when "falha_de_integracao" then "Turno expirado: a integração com o agente falhou e o caso vai para um humano (RN-45)."
    else TURN_NOTES.fetch("expired")
    end
  end

  # Turno eligible: o que a nota diz depende da publicação do evento do turno no outbox (Outbox::Publish).
  # Publicado só com published_at; encerrado sem published_at é falha sem nova tentativa (recusa do
  # broker, retentativas esgotadas ou prazo); aberto com erro está em retentativa.
  def publication_note(item)
    return "Aguardando a publicação para o agente." if item.nil? || (item.completed_at.nil? && item.last_error.nil?)
    return TURN_NOTES.fetch("eligible") if item.published_at
    return "Publicação para o agente falhou sem nova tentativa (#{item.last_error || 'descartada'})." if item.completed_at

    "Publicação para o agente falhou na tentativa #{item.attempts} e será repetida (#{item.last_error})."
  end

  # Bloco 05: ação recebida → resposta aplicada (applied + saída gravada) → resposta entregue.
  # Descartada: só o primeiro estágio. Applied sem saída (escalate, resolve sem texto): sem os estágios 2 e 3.
  def stages(record, agent_action, actions, deliveries, first_received)
    return unless agent_action

    requested = record.status == "applied" ? deliveries.requested_for_turn(record.turn) : nil
    covered = Array(record.context["pending_messages"]).filter_map { _1["seq"] }
    ConversationView::TurnStages.new(
      opened_at: record.created_at, received_at: actions.received_at(record), applied_at: requested&.occurred_at,
      delivered_at: requested && deliveries.delivered_at(requested.data["delivery_id"]),
      delivery_state: requested && deliveries.stage_state(requested.data["delivery_id"]),
      first_customer_at: first_received[covered.min], discarded: agent_action.rejected?
    )
  end

  # Bloco 03: o turno gravado em ai_turns. As mensagens cobertas são as pendentes do contexto enviado.
  # Bloco 04: a ação recebida do agente (ai_turns.response) e o seu desfecho.
  # Bloco 07: no turno superado, a mensagem que o superou e quando (RN-56).
  def turn(record, agent_action, stages, note, superseded)
    ConversationView::Turn.new(
      number: record.turn, status: record.status,
      covered_seqs: Array(record.context["pending_messages"]).map { _1["seq"] },
      context_until_seq: record.context_until_seq, assignment_version: record.assignment_version,
      event_id: record.event_id, action: record.response&.dig("action") || "—",
      note:, tool_calls: Array(record.response&.dig("tool_calls")).map { _1["tool"] },
      agent_action:, stages:, context: ConversationView::TurnContext.from(record),
      superseded_by_seq: superseded&.by_seq, superseded_at: superseded&.at
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
