module Deadlines
  class CustomerInactivity < LifecycleRegistration
    EVENT_TYPE = "customer.inactivity".freeze
    AUDIT_EVENT = "customer.inactivity_scheduled".freeze
    COLUMN = :inactivity_due_at
    STATE = "aguardando_cliente".freeze
  end
end
