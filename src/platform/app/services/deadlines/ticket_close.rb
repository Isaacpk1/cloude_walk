module Deadlines
  class TicketClose < LifecycleRegistration
    EVENT_TYPE = "ticket.close".freeze
    AUDIT_EVENT = "ticket.close_scheduled".freeze
    COLUMN = :close_due_at
    STATE = "resolvido".freeze
  end
end
