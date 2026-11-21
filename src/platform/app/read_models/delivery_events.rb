# Entrega das saídas ao canal (ROADMAP 05; 07, seções 3.2, 4 e 6; RF-06, RF-55, RF-56), lida de
# deliveries e da auditoria delivery.* que a aplicação da ação e o envio ao provedor gravam. Serve à
# conversa (status da entrega de cada mensagem de saída), ao turno (estágios aplicada e entregue) e à
# linha do tempo (um evento por auditoria, ligado ao seq da saída, ao turno e ao trace_id).
#
# Isolamento por marca (invariante 6): toda leitura filtra por brand_id e ticket_id do atendimento.
# Relógio: os horários são os da auditoria (relógio do banco) e de deliveries.delivered_at. A duração da
# chamada ao provedor vem de duration_ms, medido pelo worker.
class DeliveryEvents
  EVENT_KINDS = {
    "delivery.requested" => :delivery_requested,
    "delivery.sending" => :delivery_sending,
    "delivery.retry_scheduled" => :delivery_retry_scheduled,
    "delivery.delivered" => :delivered,
    "delivery.failed" => :delivery_failed,
    "delivery.reconciliation_needed" => :delivery_reconciliation,
    "delivery.status_received" => :delivery_status
  }.freeze

  def initialize(ticket)
    @ticket = ticket
  end

  # A entrega de uma mensagem de saída. nil para mensagem sem entrega (entrada ou anterior ao bloco 05).
  def for_message(message)
    delivery = deliveries_by_message[message.id]
    delivery && status_view(delivery)
  end

  # A auditoria delivery.requested da saída gravada pelo turno (a primeira, pela ordem do seq).
  def requested_for_turn(turn_number)
    requested.values.select { _1.data["turn"] == turn_number }.min_by { _1.data["seq"].to_i }
  end

  # Horário da confirmação do provedor: deliveries.delivered_at, ou a auditoria delivery.delivered.
  def delivered_at(delivery_id)
    deliveries_by_id[delivery_id]&.delivered_at || audits_for(delivery_id).find { _1.event_type == "delivery.delivered" }&.occurred_at
  end

  def events = audits.filter_map { event_for(_1) }

  private

  def deliveries
    @deliveries ||= Delivery.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id).order(:seq).to_a
  end

  def deliveries_by_message = @deliveries_by_message ||= deliveries.index_by(&:message_id)
  def deliveries_by_id = @deliveries_by_id ||= deliveries.index_by(&:delivery_id)

  def audits
    @audits ||= AuditEvent.where(brand_id: @ticket.brand_id, ticket_id: @ticket.id, event_type: EVENT_KINDS.keys)
                          .order(:occurred_at, :id).to_a
  end

  def audits_for(delivery_id) = (@by_delivery ||= audits.group_by { _1.data["delivery_id"] }).fetch(delivery_id, [])
  def requested = @requested ||= audits.select { _1.event_type == "delivery.requested" }.index_by { _1.data["delivery_id"] }

  def status_view(delivery)
    history = audits_for(delivery.delivery_id)
    failed = history.reverse.find { _1.event_type == "delivery.failed" }
    ConversationView::DeliveryStatus.new(
      delivery_id: delivery.delivery_id, seq: delivery.seq, kind: delivery.kind, status: delivery.status,
      attempts: delivery.attempts, provider_message_id: delivery.provider_message_id, delivered_at: delivery.delivered_at,
      last_error: delivery.last_error, failure_reason: failed&.data&.dig("reason"),
      platform_error: failed&.data&.dig("platform_error"),
      http_status: failed&.data&.dig("http_status"),
      reconciliation_needed: history.any? { _1.event_type == "delivery.reconciliation_needed" },
      next_attempt_at: scheduled_retry_at(delivery, history),
      turn: requested[delivery.delivery_id]&.data&.dig("turn")
    )
  end

  # A retentativa agendada pelo Deliveries::Send: a entrega fica em `sending` sem reserva (lease_until nulo
  # ou vencido) e o último registro da tentativa é um delivery.retry_scheduled posterior ao delivery.sending.
  # Com a reserva vigente, a tentativa seguinte está em curso; encerrada, não há retentativa.
  def scheduled_retry_at(delivery, history)
    return unless Delivery::OPEN.include?(delivery.status)
    return if delivery.lease_until && delivery.lease_until > Time.current

    last = history.reverse.find { %w[delivery.sending delivery.retry_scheduled delivery.reconciliation_needed].include?(_1.event_type) }
    parse_time(last.data["next_attempt_at"]) if last&.event_type == "delivery.retry_scheduled"
  end

  def event_for(audit)
    data = audit.data
    delivery = deliveries_by_id[data["delivery_id"]]
    return unless delivery # entrega de outro atendimento ou marca: não entra (invariante 6)

    kind = EVENT_KINDS.fetch(audit.event_type)
    started_at = audit.occurred_at
    started_at -= Rational(data["duration_ms"].to_i, 1000) if kind == :delivered && data["duration_ms"]
    TimelineView::Event.new(kind:, started_at:, finished_at: audit.occurred_at, ticket_id: @ticket.id.to_s,
                            seq: delivery.seq, turn: requested[delivery.delivery_id]&.data&.dig("turn"),
                            trace_id: audit.trace_id, source: DataSource::SYSTEM,
                            detail: detail(kind, data, delivery), error: error(kind, data))
  end

  def detail(kind, data, delivery)
    head = "Saída seq #{delivery.seq}, delivery_id #{delivery.delivery_id.first(8)}"
    case kind
    when :delivery_requested then "#{head} (#{data['kind']}) gravada com a resposta aplicada do turno #{data['turn']}"
    when :delivery_sending then "#{head}: envio ao provedor, tentativa #{data['attempt']}"
    when :delivered
      replayed = data["replayed"] ? ", confirmação repetida pelo provedor (Idempotent-Replayed)" : ""
      "#{head}: provedor aceitou na tentativa #{data['attempt']}, provider_message_id #{data['provider_message_id']}, " \
        "chamada de #{data['duration_ms']} ms#{replayed}"
    when :delivery_retry_scheduled then "#{head}: tentativa #{data['attempt']} falhou, nova tentativa agendada"
    when :delivery_failed then "#{head}: falha definitiva na tentativa #{data['attempt']}"
    when :delivery_reconciliation then "#{head}: resultado incerto após #{data['attempts']} tentativas"
    when :delivery_status
      "#{head}: provedor informou #{data['status']} (#{data['provider_message_id']}, às #{data['provider_timestamp']})"
    end
  end

  def error(kind, data)
    case kind
    when :delivery_retry_scheduled
      delivery_error(origin: "provedor_transitorio", message: data["error"], attempt: data["attempt"], retry: true,
                     next_attempt_at: parse_time(data["next_attempt_at"]))
    when :delivery_failed
      # "plataforma" na publicação é outra coisa (evento fora do contrato do broker): a entrega tem origem própria.
      origin = data["reason"] == "plataforma" ? "entrega_plataforma" : data["reason"]
      delivery_error(origin:, http_status: data["http_status"], attempt: data["attempt"],
                     message: data["platform_error"] || data["error"])
    when :delivery_reconciliation
      delivery_error(origin: "conciliacao", attempt: data["attempts"], outcome: "conciliacao_pendente")
    end
  end

  def delivery_error(origin:, http_status: nil, message: nil, attempt: nil, retry: false, next_attempt_at: nil, outcome: nil)
    TimelineView::Error.new(origin:, http_status:, message:, attempt:, retry:, next_attempt_at:, outcome:,
                            retry_key: "delivery_id")
  end

  def parse_time(value) = value && Time.zone.parse(value)
end
