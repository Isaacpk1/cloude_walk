module Deadlines
  class LifecycleRegistration < Registration
    private

    def due
      type = self.class::EVENT_TYPE
      column = self.class::COLUMN
      key_sql = "'#{type}:' || tickets.id || ':' || tickets.assignment_version || ':' || " \
                "((EXTRACT(EPOCH FROM tickets.#{column}) * 1000000)::bigint)::text"
      comparison = self.class::STATE == "resolvido" ? "<" : "<="
      relation = scoped(Ticket.where(state: self.class::STATE).where("#{column} #{comparison} ?", now))
                 .where("NOT EXISTS (SELECT 1 FROM outbox_events o WHERE o.dedup_key = #{key_sql})")
      relation.order(column, :id).limit(limit).lock("#{Ticket::ROW_LOCK} SKIP LOCKED").map do |ticket|
        deadline = ticket.public_send(column)
        key = "#{type}:#{ticket.id}:#{ticket.assignment_version}:#{(deadline.to_r * 1_000_000).to_i}"
        Due.new(ticket:, dedup_key: key, trace_id: SecureRandom.hex(16), deadline_at: deadline,
                payload: { "ticket_id" => ticket.id, "assignment_version" => ticket.assignment_version,
                           "deadline_at" => deadline.utc.iso8601(6) }, audit: { assignment_version: ticket.assignment_version })
      end
    end
  end
end
