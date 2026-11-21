# A entrega de uma mensagem de saída (07, seção 4, `deliveries`; RF-06), no formato de leitura do painel.
# O estado vem da linha de deliveries; motivo da falha, conciliação pendente, próxima tentativa e o turno
# vêm da auditoria delivery.* (bloco 05). O delivery_id é o mesmo em todas as tentativas (RNF-15).
class ConversationView::DeliveryStatus < Data.define(
  :delivery_id, :seq, :kind, :status, :attempts, :provider_message_id, :delivered_at, :last_error,
  :failure_reason, :platform_error, :http_status, :reconciliation_needed, :next_attempt_at, :turn
)
  FAILURE_REASONS = {
    "provider_failed" => "O provedor avisou que não conseguiu entregar (callback de status)",
    "seq_anterior" => "Provedor recusou: seq anterior à última aceita na conversa (409)",
    "seq_repetida" => "Provedor recusou: seq repetida, já aceita na conversa com outra chave (409)",
    "provedor_indisponivel" => "Provedor indisponível: nenhuma das tentativas foi processada (RN-43)",
    "assinatura" => "Provedor recusou a assinatura (401)",
    "contrato" => "Provedor recusou o conteúdo fora do contrato (422)",
    "eval" => "Atendimento de eval: nada sai para o broker nem para o canal (ADR-023)"
  }.freeze

  def status_label = ConversationView::Message::DELIVERY_LABELS.fetch(status)
  PLATFORM_REASON = "plataforma".freeze

  def failure_reason_label
    return unless failure_reason
    return "Recusada pela plataforma antes do envio: #{platform_error || 'motivo não registrado'}" if failure_reason == PLATFORM_REASON

    FAILURE_REASONS.fetch(failure_reason, failure_reason)
  end
  def delivered? = status == "delivered"
  def failed? = status == "failed"
  def sending? = status == "sending"
  def cancelled? = status == "cancelled"
end
