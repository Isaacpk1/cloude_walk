# Abertura de turno vencida (07, seção 3.4, "Registro dos prazos"; ADR-016). Uma volta do scheduler:
#
#   Deadlines::DispatchDue.call(now: Time.current, limit: 100) # => ids dos itens criados
#   Deadlines::DispatchDue.call(now:, limit: 1, brand_id:, ticket_ids: [id]) # só esse atendimento (eval)
#
# Numa transação, trava com FOR UPDATE SKIP LOCKED os atendimentos com dispatch_due_at <= now cuja chave
# de abertura ainda não está no outbox, e grava um `turn.dispatch` por atendimento. O próprio item é o
# marcador durável da emissão: o scheduler não limpa dispatch_due_at (quem zera é o worker, no
# Turns::Open). A chave identifica o atendimento, a atribuição e a última mensagem a cobrir, então uma
# mensagem nova ou uma nova atribuição geram outra chave. O índice único do dedup_key decide qualquer
# corrida que escape do SKIP LOCKED.
#
# Depois do commit, acorda o worker pelo ID (invariante 2). Se o Redis falhar, o item segue aberto e a
# recuperação do outbox o reoferece (07, seção 6).
module Deadlines
  class DispatchDue
    EVENT_TYPE = "turn.dispatch".freeze
    AUDIT_EVENT = "turn.dispatch_scheduled".freeze
    DEDUP_KEY_SQL = "'#{EVENT_TYPE}:' || tickets.id || ':' || tickets.assignment_version || ':' || " \
                    "tickets.latest_customer_seq".freeze

    def self.call(...) = new(...).call

    def self.dedup_key(ticket) = "#{EVENT_TYPE}:#{ticket.id}:#{ticket.assignment_version}:#{ticket.latest_customer_seq}"

    # brand_id e ticket_ids restringem a volta (o eval só toca o próprio atendimento, ADR-023). O scheduler
    # chama sem escopo: todas as marcas.
    def initialize(now:, limit:, brand_id: nil, ticket_ids: nil)
      @now = now
      @limit = limit
      @brand_id = brand_id
      @ticket_ids = ticket_ids
    end

    def call
      ids = ActiveRecord::Base.transaction { emit(due_tickets) }
      wake_worker(ids)
      ids
    end

    private

    attr_reader :now

    def due_tickets
      scope = Ticket.where(dispatch_due_at: ..now)
      scope = scope.where(brand_id: @brand_id) if @brand_id
      scope = scope.where(id: @ticket_ids) if @ticket_ids
      scope
            .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{DEDUP_KEY_SQL})")
            .order(:dispatch_due_at, :id).limit(@limit).lock("FOR UPDATE SKIP LOCKED").to_a
    end

    def emit(tickets)
      return [] if tickets.empty?

      traces = trace_ids(tickets)
      tickets.filter_map do |ticket|
        id = insert_item(ticket, traces.fetch(ticket.id))
        audit(ticket, id, traces.fetch(ticket.id)) if id
        id
      end
    end

    # trace_id da mensagem do cliente que o turno vai cobrir (seq = latest_customer_seq), da mesma marca.
    def trace_ids(tickets)
      Message.joins(:ticket).where(ticket_id: tickets.map(&:id))
             .where("messages.seq = tickets.latest_customer_seq AND messages.brand_id = tickets.brand_id")
             .pluck(:ticket_id, :trace_id).to_h
    end

    def insert_item(ticket, trace_id)
      row = {
        brand_id: ticket.brand_id, ticket_id: ticket.id, event_type: EVENT_TYPE, dedup_key: self.class.dedup_key(ticket),
        payload: payload(ticket), trace_id:, next_attempt_at: now, created_at: now
      }
      result = OutboxEvent.insert_all([ row ], unique_by: :index_outbox_events_on_dedup_key, returning: [ :id ],
                                               record_timestamps: false)
      result.rows.first&.first
    end

    def payload(ticket)
      { "ticket_id" => ticket.id, "assignment_version" => ticket.assignment_version,
        "cover_until_seq" => ticket.latest_customer_seq, "dispatch_due_at" => ticket.dispatch_due_at.iso8601(3) }
    end

    # RF-54: o atraso entre o prazo e a emissão é a métrica do scheduler no E1 (ADR-016).
    def audit(ticket, item_id, trace_id)
      AuditEvent.create!(
        brand_id: ticket.brand_id, ticket_id: ticket.id, actor_type: "system", event_type: AUDIT_EVENT, trace_id:,
        data: { outbox_event_id: item_id, dedup_key: self.class.dedup_key(ticket), cover_until_seq: ticket.latest_customer_seq,
                assignment_version: ticket.assignment_version, dispatch_due_at: ticket.dispatch_due_at.iso8601(3),
                delay_ms: ((now - ticket.dispatch_due_at) * 1000).round }
      )
    end

    def wake_worker(ids)
      ids.each { OutboxJob.perform_later(_1) }
      JsonLog.info("scheduler.dispatch_registered", count: ids.size) if ids.any?
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", source: "scheduler", count: ids.size, error: e.class.name)
    end
  end
end
