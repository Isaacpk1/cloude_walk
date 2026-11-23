# Aviso de transferência do handoff (RN-42, RF-43; 07, seção 3.2): a mensagem `system` gravada pelo Escalate e a
# entrega `handoff_notice` dela. `status`: o da entrega (pending, sending, delivered, failed, cancelled) ou :reconciling
# quando o próprio aviso ficou em conciliação. `held_by_seq`: a saída anterior em conciliação que segura o aviso
# ainda pendente (RN-38: a ordem do Deliveries::Send). Texto comum: o ERB escapa.
class ConversationView::TransferNotice < Data.define(:seq, :delivery_id, :status, :held_by_seq, :text, :attempts,
                                                     :delivered_at)
  LABELS = {
    "pending" => "Pendente", "sending" => "Enviando", "reconciling" => "Em conciliação", "delivered" => "Entregue",
    "failed" => "Falhou", "cancelled" => "Cancelada"
  }.freeze

  # `delivery`: ConversationView::DeliveryStatus da entrega do aviso; `reconciliations`: as entregas em conciliação.
  def self.from(delivery, text:, reconciliations:)
    status = delivery.sending? && delivery.reconciliation_needed ? "reconciling" : delivery.status
    held = status == "pending" ? reconciliations.select { _1.seq < delivery.seq }.min_by(&:seq)&.seq : nil
    new(seq: delivery.seq, delivery_id: delivery.delivery_id, status:, held_by_seq: held, text:, attempts: delivery.attempts,
        delivered_at: delivery.delivered_at)
  end

  def label
    base = LABELS.fetch(status, status)
    held_by_seq ? "#{base}: aguardando a conciliação da seq #{held_by_seq} (RN-38)" : base
  end
end
