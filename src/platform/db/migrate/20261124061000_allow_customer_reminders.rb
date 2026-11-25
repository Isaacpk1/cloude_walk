class AllowCustomerReminders < ActiveRecord::Migration[8.0]
  def change
    remove_check_constraint :deliveries, name: "deliveries_kind_check",
                            expression: "kind IN ('reply', 'resolution', 'progress', 'handoff_notice', 'analyst')"
    add_check_constraint :deliveries, "kind IN ('reply', 'resolution', 'progress', 'handoff_notice', 'analyst', 'reminder')",
                         name: "deliveries_kind_check"
  end
end
