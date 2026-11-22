# Base dos prazos registrados pelo scheduler (ADR-016; 07, seção 3.4, "Registro dos prazos"). Uma volta:
#
#   Deadlines::TurnTimeout.call(now:, limit:)                       # => ids dos itens criados
#   Deadlines::CycleTimeout.call(now:, limit:, brand_id:, ticket_ids:) # só esse escopo (eval, ADR-023)
#
# Numa transação, trava com FOR UPDATE SKIP LOCKED os atendimentos com o prazo vencido cuja chave ainda não
# está no outbox, revalida sob o lock e grava um item por prazo com chave única (o próprio item é o marcador
# durável da emissão; o índice único decide qualquer corrida que escape do SKIP LOCKED), com a auditoria do
# registro (`deadline_at`, `delay_ms`: o atraso do scheduler, RF-54 e E1). Depois do commit, acorda o worker
# pelo ID (invariante 2). Se o Redis falhar, o item segue aberto e a recuperação o reoferece. Nunca
# `perform_in` (invariante 5): o horário que vale é o do Postgres.
module Deadlines
  class Registration
    # Um prazo vencido: o atendimento travado e o que vai no item.
    Due = Data.define(:ticket, :dedup_key, :payload, :trace_id, :deadline_at, :audit)

    def self.call(...) = new(...).call

    def initialize(now:, limit:, brand_id: nil, ticket_ids: nil)
      @now = now
      @limit = limit
      @brand_id = brand_id
      @ticket_ids = ticket_ids
    end

    def call
      ids = ActiveRecord::Base.transaction { due.filter_map { emit(_1) } }
      wake_worker(ids)
      ids
    end

    private

    attr_reader :now, :limit

    def scoped(relation, ticket_column: :id)
      relation = relation.where(brand_id: @brand_id) if @brand_id
      relation = relation.where(ticket_column => @ticket_ids) if @ticket_ids
      relation
    end

    def emit(item)
      row = { brand_id: item.ticket.brand_id, ticket_id: item.ticket.id, event_type: self.class::EVENT_TYPE,
              dedup_key: item.dedup_key, payload: item.payload, trace_id: item.trace_id, next_attempt_at: now, created_at: now }
      id = OutboxEvent.insert_all([ row ], unique_by: :index_outbox_events_on_dedup_key, returning: [ :id ],
                                           record_timestamps: false).rows.first&.first
      return unless id

      AuditEvent.create!(
        brand_id: item.ticket.brand_id, ticket_id: item.ticket.id, actor_type: "system", event_type: self.class::AUDIT_EVENT,
        trace_id: item.trace_id,
        data: item.audit.merge(outbox_event_id: id, dedup_key: item.dedup_key, deadline_at: iso(item.deadline_at),
                               delay_ms: ((now - item.deadline_at) * 1000).round)
      )
      id
    end

    def iso(time) = time.utc.iso8601(3)

    def wake_worker(ids)
      ids.each { OutboxJob.perform_later(_1) }
      JsonLog.info("scheduler.#{self.class::EVENT_TYPE.tr('.', '_')}_registered", count: ids.size) if ids.any?
    rescue StandardError => e
      JsonLog.warn("outbox.enqueue_failed", source: "scheduler", event_type: self.class::EVENT_TYPE, count: ids.size,
                                            error: e.class.name)
    end
  end
end
