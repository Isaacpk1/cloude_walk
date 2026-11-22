# Tentativas e desfecho de cada item do outbox ligado ao atendimento (ROADMAP 09, Frontend; RF-34, RNF-16,
# RN-43, RN-44; 07, seção 6). Lê outbox_events (attempts, last_error, next_attempt_at, published_at,
# completed_at) e a auditoria de cada tentativa:
# - publicação do turno ("agent.event"): agent_event.published/publish_failed/rejected/discarded, ligadas
#   pelo event_id (Outbox::Publish);
# - entrega ("delivery.requested"): delivery.sending/retry_scheduled/delivered/failed/cancelled/
#   reconciliation_needed, ligadas pelo delivery_id (Deliveries::Send), e delivery.discarded pelo item;
# - recuperação (bloco 09): outbox.recovered e outbox.closed_obsolete, ligadas pelo outbox_event_id (ou
#   event_id, o mesmo valor) do item.
# Os tipos novos dos blocos 08 e 09 (handoff, prazos, aviso) entram com o resumo genérico do item. Ficam de
# fora o aviso da ingestão ("message.received") e a ação da janela ("turn.dispatch"): o painel já mostra a
# gravação e a abertura do turno, e eles não têm tentativa a explicar.
#
# Erros: o mesmo TimelineView::Error da linha do tempo (PublicationEvents.error_for e DeliveryEvents.error_for),
# para o motivo não ser escrito em mais de um lugar. Isolamento por marca (invariante 6): itens e auditoria só
# da marca e do atendimento.
class OutboxAttempts
  HIDDEN_TYPES = %w[message.received turn.dispatch].freeze
  PUBLICATION = %w[agent_event.published agent_event.publish_failed agent_event.rejected agent_event.discarded].freeze
  DELIVERY = %w[delivery.sending delivery.retry_scheduled delivery.delivered delivery.failed delivery.cancelled
                delivery.reconciliation_needed delivery.requested].freeze
  RECOVERY = %w[outbox.recovered outbox.closed_obsolete delivery.discarded].freeze
  DELIVERY_RESULTS = { "delivery.retry_scheduled" => "Falhou, nova tentativa agendada", "delivery.delivered" => "Entregue",
                       "delivery.failed" => "Falhou definitivo" }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  def items = @items ||= records.map { view(_1) }

  # Um evento da linha do tempo por item: da criação ao encerramento, com o resumo "N tentativas · desfecho".
  def events
    items.map do |item|
      finished_at = item.completed_at && [ item.completed_at, item.created_at ].max
      TimelineView::Event.new(kind: :outbox_item, started_at: item.created_at, finished_at:, ticket_id: @ticket.id.to_s,
                              seq: item.seq, turn: item.turn, trace_id: item.trace_id, source: DataSource::SYSTEM,
                              detail: "#{item.type_label} (#{item.event_type} #{item.id.first(8)}): #{item.summary}",
                              outbox: item)
    end
  end

  private

  def records
    OutboxEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).where.not(event_type: HIDDEN_TYPES)
               .order(:created_at, :id).to_a
  end

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: PUBLICATION + DELIVERY + RECOVERY)
                          .order(:occurred_at, :id).to_a
  end

  def turns = @turns ||= @ticket.ai_turns.where(brand_id: @ticket.brand_id).index_by(&:event_id)
  def deliveries = @deliveries ||= Delivery.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).index_by(&:delivery_id)

  def by_item(item) = audits.select { RECOVERY.include?(_1.event_type) && (_1.data["outbox_event_id"] || _1.data["event_id"]) == item.id }

  def view(item)
    case item.event_type
    when Turns::Open::EVENT_TYPE then publication_view(item)
    when Deliveries::Send::EVENT_TYPE then delivery_view(item)
    else generic_view(item)
    end
  end

  # --- Publicação do turno ---

  def publication_view(item)
    history = audits.select { PUBLICATION.include?(_1.event_type) && _1.data["event_id"] == item.id }
    entries = history.map { publication_attempt(_1) }
    turn = turns[item.id]
    build(item, entries, publication_outcome(item, history), turn: turn&.turn, seq: turn&.context_until_seq)
  end

  def publication_attempt(audit)
    data = audit.data
    return attempt(data["attempt"], audit.occurred_at, "Publicado", duration_ms: data["duration_ms"]) if audit.event_type == "agent_event.published"

    error = PublicationEvents.error_for(audit)
    label = case audit.event_type
    when "agent_event.discarded" then "Descartado"
    when "agent_event.rejected" then "Recusado"
    else error.retry ? "Falhou, nova tentativa agendada" : "Falhou definitivo"
    end
    attempt(data["attempt"], audit.occurred_at, label, error:, next_attempt_at: error.retry ? error.next_attempt_at : nil)
  end

  def publication_outcome(item, history)
    return [ :published ] if item.published_at

    last = history.last
    case last&.event_type
    when "agent_event.discarded" then [ :discarded, PublicationEvents.error_for(last).origin_label ]
    when "agent_event.rejected" then [ :failed, PublicationEvents.error_for(last).origin_label ]
    when "agent_event.publish_failed"
      error = PublicationEvents.error_for(last)
      error.retry ? nil : [ :failed, error.outcome_label || error.origin_label ]
    end
  end

  # --- Entrega ao canal ---

  def delivery_view(item)
    delivery_id = item.payload["delivery_id"]
    history = audits.select { DELIVERY.include?(_1.event_type) && _1.data["delivery_id"] == delivery_id }
    requested = history.find { _1.event_type == "delivery.requested" }
    build(item, delivery_entries(history), delivery_outcome(deliveries[delivery_id], history),
          delivery_id:, seq: item.payload["seq"], turn: requested&.data&.dig("turn"))
  end

  # Cada tentativa vai do delivery.sending ao resultado com o mesmo número; conciliação e cancelamento são
  # registros do item, sem número de tentativa.
  def delivery_entries(history)
    sending = history.select { _1.event_type == "delivery.sending" }.index_by { _1.data["attempt"] }
    results = history.select { DELIVERY_RESULTS.key?(_1.event_type) }
    entries = results.map { delivery_attempt(_1, sending[_1.data["attempt"]]) }
    entries += (sending.keys - results.map { _1.data["attempt"] }).map do |number|
      attempt(number, sending[number].occurred_at, "Sem resultado registrado (em curso ou abandonada)")
    end
    entries + history.filter_map do |audit|
      case audit.event_type
      when "delivery.reconciliation_needed"
        attempt(nil, audit.occurred_at, "Em conciliação", error: DeliveryEvents.error_for(:delivery_reconciliation, audit.data))
      when "delivery.cancelled"
        attempt(nil, audit.occurred_at, "Cancelada", error: DeliveryEvents.error_for(:delivery_cancelled, audit.data))
      end
    end
  end

  def delivery_attempt(result, sending)
    data = result.data
    kind = DeliveryEvents::EVENT_KINDS.fetch(result.event_type)
    error = DeliveryEvents.error_for(kind, data)
    started = sending&.occurred_at || result.occurred_at
    duration_ms = data["duration_ms"] || TimelineView::Event.ms_between(started, [ result.occurred_at, started ].max)
    attempt(data["attempt"], started, DELIVERY_RESULTS.fetch(result.event_type), duration_ms:, error:,
                                                                                next_attempt_at: error&.retry ? error.next_attempt_at : nil)
  end

  def delivery_outcome(delivery, history)
    return [ :delivered ] if delivery&.status == "delivered"

    if delivery&.status == "failed" && (failed = history.reverse.find { _1.event_type == "delivery.failed" })
      return [ :failed, DeliveryEvents.error_for(:delivery_failed, failed.data).origin_label ]
    end
    if delivery&.status == "cancelled" && (cancelled = history.reverse.find { _1.event_type == "delivery.cancelled" })
      return [ :cancelled, DeliveryEvents.error_for(:delivery_cancelled, cancelled.data).origin_label ]
    end

    [ :reconciliation ] if delivery&.status == "sending" && history.any? { _1.event_type == "delivery.reconciliation_needed" }
  end

  # --- Demais tipos (blocos 08 e 09) ---

  def generic_view(item)
    build(item, [], nil, turn: item.payload["turn"])
  end

  # --- Comum: recuperação e desfecho do item ---

  def build(item, entries, outcome, turn: nil, seq: nil, delivery_id: nil)
    recovery = by_item(item)
    entries = (entries + recovery.map { recovery_entry(_1) }).sort_by.with_index { |entry, i| [ entry.at, entry.number ? 0 : 1, i ] }
    outcome ||= closing_outcome(item, recovery)
    OutboxView.new(
      id: item.id, event_type: item.event_type, turn:, seq:, delivery_id:, attempts_count: item.attempts,
      outcome: outcome.first, outcome_detail: outcome.second, attempts: entries, last_error: item.last_error,
      next_attempt_at: item.completed_at ? nil : item.next_attempt_at, created_at: item.created_at,
      completed_at: item.completed_at, recovered_count: recovery.count { _1.event_type == "outbox.recovered" },
      trace_id: item.trace_id
    )
  end

  def recovery_entry(audit)
    data = audit.data
    case audit.event_type
    when "outbox.recovered"
      attempt(nil, audit.occurred_at, "Reoferecido pela recuperação (tentativas até então: #{data['attempts'].to_i})")
    when "outbox.closed_obsolete"
      attempt(nil, audit.occurred_at, outcome_label(:closed_obsolete, reason_label(data["reason"])), error: reason_error(data["reason"]))
    else
      attempt(nil, audit.occurred_at, "Descartado: #{data['reason']}")
    end
  end

  # Desfecho pelo próprio item, quando a auditoria da etapa não decidiu: obsolescência, descarte da entrega
  # inexistente, conclusão genérica ou o estado do item aberto.
  def closing_outcome(item, recovery)
    obsolete = recovery.reverse.find { _1.event_type == "outbox.closed_obsolete" }
    return [ :closed_obsolete, reason_label(obsolete.data["reason"]) ] if obsolete

    discarded = recovery.reverse.find { _1.event_type == "delivery.discarded" }
    return [ :discarded, discarded.data["reason"] ] if discarded
    return [ :completed, item.last_error.presence ] if item.completed_at
    return [ :recovered ] if recovery.last&.event_type == "outbox.recovered"
    return [ :retrying ] if item.last_error
    return [ :in_progress ] if item.lease_until && item.lease_until > Time.current

    [ :pending ]
  end

  def reason_label(reason) = reason && TimelineView::Error::ORIGINS.fetch(reason, reason)
  def outcome_label(outcome, detail) = [ OutboxView::OUTCOMES.fetch(outcome), detail ].compact.join(": ")

  def reason_error(reason)
    TimelineView::Error.new(origin: reason, http_status: nil, message: nil, attempt: nil, retry: false, next_attempt_at: nil,
                            outcome: "obsoleto")
  end

  def attempt(number, at, result_label, duration_ms: nil, error: nil, next_attempt_at: nil)
    OutboxView::Attempt.new(number:, at:, duration_ms:, error:, next_attempt_at:, result_label:)
  end
end
