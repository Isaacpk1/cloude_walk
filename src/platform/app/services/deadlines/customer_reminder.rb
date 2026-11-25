module Deadlines
  class CustomerReminder < LifecycleRegistration
    EVENT_TYPE = "customer.reminder".freeze
    AUDIT_EVENT = "customer.reminder_scheduled".freeze
    COLUMN = :reminder_due_at
    STATE = "aguardando_cliente".freeze
  end
end
