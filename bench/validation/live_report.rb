# Fotografia dos casos criados pelo roteiro live_chat desde VALIDATION_RUN (UTC).
# Só leitura; não afirma sucesso a partir de contêiner saudável.
abort "somente em development" unless Rails.env.development?
run = ENV.fetch("VALIDATION_RUN")
abort "VALIDATION_RUN deve ter AAAAMMDDhhmmss" unless run.match?(/\A\d{14}\z/)
started = Time.strptime(run + " UTC", "%Y%m%d%H%M%S %Z")
brand_ids = Brand.where(slug: [ "validacao-#{run}", "infinitepay", "jim" ]).pluck(:id)
message_scope = Message.where(brand_id: brand_ids, direction: "inbound", received_at: started..)
                       .where("external_id LIKE ?", "validacao-%")
records = Ticket.where(brand_id: brand_ids, id: message_scope.select(:ticket_id)).order(:id).map do |ticket|
  audits = AuditEvent.where(brand_id: ticket.brand_id, ticket_id: ticket.id).order(:id)
  {
    ticket_id: ticket.id, brand: ticket.brand.slug, state: ticket.state, queue_id: ticket.queue_id,
    ruleset_version: ticket.ruleset_version, sla_started_at: ticket.sla_started_at, sla_due_at: ticket.sla_due_at,
    messages: message_scope.where(brand_id: ticket.brand_id, ticket_id: ticket.id).order(:seq).pluck(:external_id, :seq, :trace_id),
    routing: audits.where(event_type: "routing.decided").map { { trace_id: _1.trace_id, data: _1.data } },
    turns: AiTurn.where(brand_id: ticket.brand_id, ticket_id: ticket.id).order(:turn).pluck(:turn, :status, :event_id, :applied_event_id),
    deliveries: Delivery.where(brand_id: ticket.brand_id, ticket_id: ticket.id).order(:seq).pluck(:delivery_id, :seq, :status, :last_error),
    events: audits.map { { type: _1.event_type, at: _1.occurred_at, trace_id: _1.trace_id } }
  }
end
configuration_events = AuditEvent.where(brand_id: brand_ids, ticket_id: nil, occurred_at: started..)
                                 .order(:id).map { { brand_id: _1.brand_id, type: _1.event_type, at: _1.occurred_at, data: _1.data } }
puts JSON.pretty_generate(observed_at: Time.current.utc, run:,
                          method: "HTTP, Kafka, scheduler e worker reais; consultas da plataforma no Postgres",
                          configuration_events:, cases: records)
