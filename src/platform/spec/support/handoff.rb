# Handoff mínimo do bloco 08 (interface combinada, item 1; 07, seção 3.2). Fila padrão da marca com uma
# versão publicada e o pedido de handoff gravado como os gatilhos gravam: com o atendimento travado.
module HandoffHelpers
  def default_queue(brand)
    team = create(:team, brand:)
    queue = create(:queue_record, team:, brand:, is_default: true)
    queue.publish_version!(name: "Geral", created_by: nil)
    queue.reload
  end

  def request_handoff(ticket, reason: "prazo_do_turno", source: "scheduler", turn: nil)
    ActiveRecord::Base.transaction do
      locked = Ticket.lock.find_by!(id: ticket.id, brand_id: ticket.brand_id)
      Handoff::Request.call(ticket: locked, reason:, source:, turn:, trace_id: "c" * 32)
    end
  end

  def handoff_items(ticket = nil)
    scope = OutboxEvent.where(event_type: Handoff::Request::EVENT_TYPE)
    scope = scope.where(ticket_id: ticket.id) if ticket
    scope.order(:created_at, :id)
  end

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)
end

RSpec.configure { |c| c.include HandoffHelpers }
