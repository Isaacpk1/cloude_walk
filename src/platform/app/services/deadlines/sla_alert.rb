# Alerta de SLA aos 80% do prazo de assunção (RN-25; 07, seção 3.5; ADR-016). Caso em `aguardando_humano`, sem
# analista, com SLA iniciado, ainda sem alerta e com `sla_started_at + 0,8 × (sla_due_at − sla_started_at) <= now`
# vira um item `sla.alert` com a chave `sla.alert:<ticket_id>:<assignment_version>` (uma atribuição nova, como a
# devolução à fila, gera chave nova). O worker (Sla::Alert) revalida sob o lock e sobe a prioridade um nível.
module Deadlines
  class SlaAlert < Registration
    EVENT_TYPE = "sla.alert".freeze
    AUDIT_EVENT = "sla.alert_scheduled".freeze
    THRESHOLD = 0.8
    KEY_SQL = "'#{EVENT_TYPE}:' || tickets.id || ':' || tickets.assignment_version".freeze
    ALERT_AT_SQL = "tickets.sla_started_at + (tickets.sla_due_at - tickets.sla_started_at) * #{THRESHOLD}".freeze

    def self.dedup_key(ticket) = "#{EVENT_TYPE}:#{ticket.id}:#{ticket.assignment_version}"

    # O instante dos 80% de um caso com SLA iniciado.
    def self.alert_at(ticket) = ticket.sla_started_at + ((ticket.sla_due_at - ticket.sla_started_at) * THRESHOLD)

    private

    def due
      scoped(Ticket.where(state: "aguardando_humano", assignee_id: nil, sla_alerted_at: nil, sla_breached: false)
                   .where.not(sla_due_at: nil).where("#{ALERT_AT_SQL} <= ?", now))
        .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{KEY_SQL})")
        .order(Arel.sql(ALERT_AT_SQL), :id).limit(limit).lock("#{Ticket::ROW_LOCK} SKIP LOCKED").to_a.map do |ticket|
        Due.new(ticket:, dedup_key: self.class.dedup_key(ticket), trace_id: SecureRandom.hex(16),
                deadline_at: self.class.alert_at(ticket),
                payload: { "ticket_id" => ticket.id, "assignment_version" => ticket.assignment_version,
                           "sla_started_at" => iso(ticket.sla_started_at), "sla_due_at" => iso(ticket.sla_due_at) },
                audit: { assignment_version: ticket.assignment_version, sla_due_at: iso(ticket.sla_due_at),
                         priority: ticket.priority })
      end
    end
  end
end
