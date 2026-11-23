# Evento de auditoria (RF-54, RN-54). Só inserção: o banco recusa UPDATE e DELETE.
class AuditEvent < ApplicationRecord
  # Bloco 10 (RNF-06; 07, seção 3.2 "Broadcast por ActionCable"): a entrada na fila humana e o resumo pedem a recarga
  # da fila (geral e da marca) e da conversa no painel. Só depois do commit: num rollback não sai nada, e nenhuma
  # chamada ao ActionCable acontece com a transação aberta (invariante 2). O stream leva só o pedido de recarga, sem
  # dado do caso: a página recarrega pelo próprio escopo de marca (invariante 6).
  PANEL_EVENTS = %w[ticket.escalated handoff.summary_available handoff.summary_missing ticket.returned_to_queue
                    ticket.priority_raised sla.breached analyst.availability_changed ticket.resolved analyst.replied
                    analyst.noted].freeze
  # Bloco 11 (RN-28): a triagem que manda o caso novo direto à fila humana também é uma entrada na fila.
  HUMAN_QUEUE_ASSIGNMENT = "ticket.assigned".freeze
  # Bloco 13 (RF-45): a atribuição da distribuição a um analista também muda a fila.
  PANEL_ASSIGNMENTS = %w[fila_humana analista].freeze

  belongs_to :brand
  belongs_to :ticket, optional: true, inverse_of: :audit_events

  after_create_commit :refresh_panel, if: :panel_event?

  def readonly? = persisted?

  private

  def panel_event?
    PANEL_EVENTS.include?(event_type) || (event_type == HUMAN_QUEUE_ASSIGNMENT && PANEL_ASSIGNMENTS.include?(data.to_h.with_indifferent_access[:to]))
  end

  # O aviso é só conveniência: falhar aqui (ActionCable ou Redis fora do ar) não desfaz nada nem derruba quem gravou;
  # o caso já está na fila e aparece na próxima leitura.
  def refresh_panel
    streams = HumanQueue.streams_for(brand)
    streams << ConversationView.stream_for(brand.slug, ticket_id) if ticket_id
    streams.each { Turbo::StreamsChannel.broadcast_refresh_to(*_1) }
  rescue StandardError => e
    JsonLog.warn("panel.broadcast_failed", trace_id:, event_type:, ticket_id:, error: e.class.name)
  end
end
