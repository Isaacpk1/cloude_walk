# Os três estágios da resposta de um turno (ROADMAP 05): ação recebida, resposta aplicada (turno applied e
# saída gravada) e resposta entregue ao canal. Cada duração vai do estágio anterior ao seguinte, com os
# tempos do sistema: a ação recebida conta desde a abertura do turno. O tempo total percebido (RNF-05) vai
# da primeira mensagem do cliente coberta pelo turno até a entrega e inclui a janela de agrupamento, que é
# espera intencional (RN-55). Turno descartado só tem o primeiro estágio. O estágio entregue e o tempo
# total só existem com a entrega em delivered (delivery_state, de DeliveryEvents#stage_state).
class ConversationView::TurnStages < Data.define(:opened_at, :received_at, :applied_at, :delivered_at,
                                                 :first_customer_at, :discarded, :delivery_state)
  def initialize(delivery_state: nil, **rest) = super
  def received_ms = ms(opened_at, received_at)
  def applied_ms = ms(received_at, applied_at)
  def delivered_ms = ms(applied_at, delivered_at)
  def perceived_total_ms = ms(first_customer_at, delivered_at)
  def discarded? = discarded
  def failed_after_delivered? = delivery_state == :failed_after_delivered
  def not_delivered? = delivery_state == :not_delivered

  private

  def ms(from, to) = from && to && TimelineView::Event.ms_between(from, to)
end
