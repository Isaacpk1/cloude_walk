# RF-47: os atendimentos anteriores do mesmo cliente (de qualquer canal), do mais novo ao mais antigo. O cliente já é
# único por marca (RN-05), então filtrar por `customer_id` e `brand_id` não mistura marcas (RN-52).
class CustomerHistory
  LIMIT = 10
  Entry = Data.define(:ticket_id, :channel, :state, :created_at)

  def self.for(ticket_id, brand_ids)
    ticket = Ticket.find_by(id: ticket_id, brand_id: brand_ids)
    return [] unless ticket

    Ticket.where(brand_id: ticket.brand_id, customer_id: ticket.customer_id).where.not(id: ticket.id)
          .order(id: :desc).limit(LIMIT)
          .map { Entry.new(ticket_id: _1.id, channel: _1.channel, state: _1.state, created_at: _1.created_at) }
  end
end
