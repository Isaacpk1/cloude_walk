# Evento de auditoria (RF-54, RN-54). Só inserção: o banco recusa UPDATE e DELETE.
class AuditEvent < ApplicationRecord
  # Bloco 10 (RNF-06; 07, seção 3.2 "Broadcast por ActionCable"): a entrada na fila humana e o resumo pedem a recarga
  # da fila (geral e da marca) e da conversa no painel. Só depois do commit: num rollback não sai nada, e nenhuma
  # chamada ao ActionCable acontece com a transação aberta (invariante 2). O stream leva só o pedido de recarga, sem
  # dado do caso: a página recarrega pelo próprio escopo de marca (invariante 6).
  PANEL_EVENTS = %w[ticket.escalated handoff.summary_available handoff.summary_missing].freeze

  belongs_to :brand
  belongs_to :ticket, optional: true, inverse_of: :audit_events

  after_create_commit :refresh_panel, if: -> { PANEL_EVENTS.include?(event_type) }

  def readonly? = persisted?

  private

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
