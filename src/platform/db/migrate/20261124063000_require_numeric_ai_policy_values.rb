class RequireNumericAiPolicyValues < ActiveRecord::Migration[8.0]
  def change
    fields = %w[turn_deadline cycle_deadline progress_notice chat_window whatsapp_window email_window ceiling]
    expression = fields.map { "jsonb_typeof(settings->'#{_1}') = 'number'" }.join(" AND ")
    add_check_constraint :ai_policy_versions, expression, name: "ai_policy_numeric_values"
  end
end
