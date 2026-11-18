# Uma troca de responsável no histórico do atendimento (07, seção 3.2), vinda de `audit_events`.
class ConversationView::Escalation < Data.define(:occurred_at, :from, :to, :trigger, :reason, :assignment_version)
end
