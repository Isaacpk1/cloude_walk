# Estouro do SLA de assunção (RN-26; 07, seção 3.5; ADR-016). Caso em `aguardando_humano`, sem analista e ainda não
# marcado, com `sla_due_at <= now`, vira um item `sla.breach` com a chave
# `sla.breach:<ticket_id>:<assignment_version>`. O worker (Sla::Breach) revalida sob o lock e marca `sla_breached`.
# Com analista, a assunção foi cumprida e não há o que marcar.
module Deadlines
  class SlaBreach < Registration
    EVENT_TYPE = "sla.breach".freeze
    AUDIT_EVENT = "sla.breach_scheduled".freeze
    KEY_SQL = "'#{EVENT_TYPE}:' || tickets.id || ':' || tickets.assignment_version".freeze

    def self.dedup_key(ticket) = "#{EVENT_TYPE}:#{ticket.id}:#{ticket.assignment_version}"

    private

    def due
      scoped(Ticket.where(state: "aguardando_humano", assignee_id: nil, sla_breached: false).where(sla_due_at: ..now))
        .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{KEY_SQL})")
        .order(:sla_due_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").to_a.map do |ticket|
        Due.new(ticket:, dedup_key: self.class.dedup_key(ticket), trace_id: SecureRandom.hex(16),
                deadline_at: ticket.sla_due_at,
                payload: { "ticket_id" => ticket.id, "assignment_version" => ticket.assignment_version,
                           "sla_due_at" => iso(ticket.sla_due_at) },
                audit: { assignment_version: ticket.assignment_version, sla_due_at: iso(ticket.sla_due_at) })
      end
    end
  end
end
