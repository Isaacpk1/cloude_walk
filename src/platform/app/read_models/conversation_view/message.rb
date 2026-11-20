# Uma linha de `messages` (07, seção 4) com o status da sua entrega em `deliveries`. `delivery`
# (ConversationView::DeliveryStatus) traz o detalhe da entrega nos registros do sistema (bloco 05).
class ConversationView::Message < Data.define(
  :seq, :author_type, :author_name, :body, :direction, :internal,
  :occurred_at, :trace_id, :delivery_status, :delivery_id, :delivery
)
  AUTHOR_LABELS = { "customer" => "Cliente", "bot" => "Bot", "analyst" => "Analista", "system" => "Sistema" }.freeze
  DELIVERY_LABELS = {
    "pending" => "Pendente", "sending" => "Enviando", "delivered" => "Entregue",
    "cancelled" => "Cancelada", "failed" => "Falhou"
  }.freeze

  def initialize(author_type:, delivery_status:, delivery: nil, **rest)
    raise ArgumentError, "author_type desconhecido: #{author_type}" unless AUTHOR_LABELS.key?(author_type)
    if delivery_status && !DELIVERY_LABELS.key?(delivery_status)
      raise ArgumentError, "delivery_status desconhecido: #{delivery_status}"
    end

    super(author_type:, delivery_status:, delivery:, **rest)
  end

  def author_label = AUTHOR_LABELS.fetch(author_type)
  def delivery_label = delivery_status && DELIVERY_LABELS.fetch(delivery_status)
  def customer? = author_type == "customer"
  def inbound? = direction == "inbound"
end
