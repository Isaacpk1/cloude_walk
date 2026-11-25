# Analista offline há 10 minutos (RN-31; 07, seção 3.5; ADR-016). Casos dele em `com_analista` ou
# `aguardando_cliente`, com o analista em `offline` e `status_changed_at <= now - 10 min`, viram um item
# `analyst.offline` com a chave `analyst.offline:<ticket_id>:<assignment_version>`: uma atribuição nova gera outra
# chave, e repetir a volta não duplica. O worker (Distribution::ReturnToQueue) revalida sob o lock e devolve o caso
# à fila. Só `offline` conta: pausa não devolve (RN-31).
module Deadlines
  class AnalystOffline < Registration
    EVENT_TYPE = "analyst.offline".freeze
    AUDIT_EVENT = "analyst.offline_scheduled".freeze
    OFFLINE_AFTER = 10.minutes
    STATES = %w[com_analista aguardando_cliente].freeze
    KEY_SQL = "'#{EVENT_TYPE}:' || tickets.id || ':' || tickets.assignment_version".freeze

    def self.dedup_key(ticket) = "#{EVENT_TYPE}:#{ticket.id}:#{ticket.assignment_version}"

    private

    def due
      tickets = scoped(Ticket.joins("JOIN users offline ON offline.id = tickets.assignee_id")
                             .where(state: STATES)
                             .where("offline.status = 'offline' AND offline.status_changed_at <= ?", now - OFFLINE_AFTER)
                             .select("tickets.*", "offline.status_changed_at AS offline_since"))
                .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{KEY_SQL})")
                .order("offline.status_changed_at", :id).limit(limit).lock("#{Ticket::ROW_LOCK} OF tickets SKIP LOCKED").to_a
      tickets.map do |ticket|
        since = ticket.offline_since
        Due.new(ticket:, dedup_key: self.class.dedup_key(ticket), trace_id: SecureRandom.hex(16),
                deadline_at: since + OFFLINE_AFTER,
                payload: { "ticket_id" => ticket.id, "assignee_id" => ticket.assignee_id,
                           "assignment_version" => ticket.assignment_version, "offline_since" => iso(since) },
                audit: { assignee_id: ticket.assignee_id, assignment_version: ticket.assignment_version,
                         offline_since: iso(since) })
      end
    end
  end
end
