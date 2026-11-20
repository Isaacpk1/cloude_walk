# A entrega de uma mensagem de saída (07, seção 4, `deliveries`; RF-06), no formato de leitura do painel.
# O estado vem da linha de deliveries; motivo da falha, conciliação pendente, próxima tentativa e o turno
# vêm da auditoria delivery.* (bloco 05). O delivery_id é o mesmo em todas as tentativas (RNF-15).
class ConversationView::DeliveryStatus < Data.define(
  :delivery_id, :seq, :kind, :status, :attempts, :provider_message_id, :delivered_at, :last_error,
  :failure_reason, :http_status, :reconciliation_needed, :next_attempt_at, :turn
)
  FAILURE_REASONS = {
    "provider_failed" => "O provedor avisou que não conseguiu entregar (callback de status)",
    "seq_anterior" => "Provedor recusou: seq anterior à última aceita na conversa (409)",
    "assinatura" => "Provedor recusou a assinatura (401)",
    "contrato" => "Provedor recusou o conteúdo fora do contrato (422)"
  }.freeze

  def status_label = ConversationView::Message::DELIVERY_LABELS.fetch(status)
  def failure_reason_label = failure_reason && FAILURE_REASONS.fetch(failure_reason, failure_reason)
  def delivered? = status == "delivered"
  def failed? = status == "failed"
  def sending? = status == "sending"
end
