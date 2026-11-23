# Gatilho, motivo e desfecho de um prazo, de um handoff ou do aviso de progresso na linha do tempo (ROADMAP 08; RN-46,
# RN-57, RF-36). `origin`: quem agiu (scheduler, outbox, turns, dlq, worker); `reason`: o código gravado na auditoria e
# `reason_label` o seu rótulo; `outcome`: o que aconteceu depois. Tudo texto comum: o ERB escapa.
class TimelineView::Cause < Data.define(:origin, :reason, :reason_label, :outcome)
  ORIGINS = ConversationView::Handoff::SOURCES.merge("worker" => "Worker: ação do outbox revalidada sob o lock").freeze

  def initialize(origin:, reason:, reason_label: nil, outcome: nil)
    super(origin:, reason:, reason_label: reason_label || reason, outcome:)
  end

  def origin_label = ORIGINS.fetch(origin, origin)
end
