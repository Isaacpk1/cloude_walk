# Um evento da linha do tempo. A duração sai dos tempos registrados, nunca de um valor digitado.
# `error` (TimelineView::Error) fica preenchido nas etapas que falharam: a tela mostra a origem ao
# escolher o evento (ROADMAP 03). `agent_action` (AgentActionView) fica preenchido nos eventos da ação
# recebida do agente: a tela mostra as consultas e a ação ao escolher o evento (ROADMAP 04). `cause`
# (TimelineView::Cause) fica preenchido nos prazos, no turno expirado, no handoff e no aviso de progresso (bloco 08):
# a tela mostra o gatilho, o motivo e o desfecho ao escolher o evento. `outbox` (OutboxView) fica preenchido no
# resumo das tentativas de um item do outbox e `dead_letter` (DeadLetterView) no evento da DLQ (ROADMAP 09).
class TimelineView::Event < Data.define(:kind, :started_at, :finished_at, :ticket_id, :seq, :turn, :trace_id, :detail,
                                        :source, :error, :agent_action, :cause, :outbox, :dead_letter)
  LABELS = {
    received: "Recebimento",
    persisted: "Gravação",
    intentional_wait: "Espera intencional (janela de agrupamento)",
    turn_opened: "Abertura do turno",
    turn_not_opened: "Turno não aberto",
    turn_superseded: "Turno superado",
    published: "Publicação no broker",
    publish_failed: "Falha na publicação",
    publish_discarded: "Publicação cancelada",
    agent_run: "Execução do agente",
    applied: "Aplicação da resposta",
    discarded: "Descarte da resposta",
    escalated: "Escalado para humano",
    assigned: "Atribuição",
    delivery_requested: "Saída gravada para entrega",
    delivery_sending: "Envio ao canal",
    delivery_retry_scheduled: "Retentativa da entrega agendada",
    delivered: "Entrega ao canal",
    delivery_failed: "Falha na entrega",
    delivery_cancelled: "Entrega cancelada",
    delivery_reconciliation: "Entrega em conciliação",
    delivery_status: "Status do provedor",
    timeout_scheduled: "Prazo vencido registrado pelo scheduler",
    turn_expired: "Turno expirado",
    handoff_requested: "Pedido de handoff",
    handoff_discarded: "Pedido de handoff descartado",
    timeout_discarded: "Prazo descartado pelo worker",
    progress_scheduled: "Aviso de progresso agendado",
    progress_sent: "Aviso de progresso enviado",
    progress_discarded: "Aviso de progresso descartado",
    human_requested: "Pedido de humano pelo cliente",
    priority_raised: "Prioridade subiu",
    summary_available: "Resumo disponível",
    summary_missing: "Sem resumo",
    triage_classified: "Triagem",
    routing_decided: "Roteamento",
    triage_assigned: "Atribuição pela triagem",
    triage_skipped: "Triagem pulada",
    outbox_item: "Tentativas e desfecho",
    dead_letter: "DLQ"
  }.freeze

  # Etapa do fluxo de cada tipo de evento (ROADMAP 09: "motivo da falha em cada etapa"). O evento DLQ fica na
  # etapa de quem o desviou (DeadLetterView::STAGES); o resumo do item do outbox não é etapa.
  STAGES = { ingestao: "Ingestão", publicacao: "Publicação", agente: "Agente", aplicacao: "Aplicação", entrega: "Entrega" }.freeze
  STAGE_BY_KIND = {
    received: :ingestao, persisted: :ingestao,
    intentional_wait: :publicacao, turn_opened: :publicacao, turn_not_opened: :publicacao, turn_superseded: :publicacao,
    published: :publicacao, publish_failed: :publicacao, publish_discarded: :publicacao,
    agent_run: :agente, applied: :aplicacao, discarded: :aplicacao, escalated: :aplicacao, assigned: :aplicacao,
    human_requested: :ingestao, priority_raised: :aplicacao, summary_available: :aplicacao, summary_missing: :aplicacao,
    delivery_requested: :entrega, delivery_sending: :entrega, delivery_retry_scheduled: :entrega, delivered: :entrega,
    delivery_failed: :entrega, delivery_cancelled: :entrega, delivery_reconciliation: :entrega, delivery_status: :entrega
  }.freeze

  def self.ms_between(from, to) = ((to - from) * 1000).round

  def initialize(kind:, started_at:, finished_at:, error: nil, agent_action: nil, cause: nil, outbox: nil, dead_letter: nil,
                 **rest)
    raise ArgumentError, "kind desconhecido: #{kind}" unless LABELS.key?(kind)
    if finished_at && finished_at < started_at
      raise ArgumentError, "finished_at (#{finished_at}) antes de started_at (#{started_at})"
    end

    super(kind:, started_at:, finished_at:, error:, agent_action:, cause:, outbox:, dead_letter:, **rest)
  end

  def label = LABELS.fetch(kind)
  def duration_ms = finished_at && self.class.ms_between(started_at, finished_at)
  def intentional_wait? = kind == :intentional_wait
  def error? = !error.nil?
  def stage = kind == :dead_letter ? dead_letter&.stage : STAGE_BY_KIND[kind]

  # Por que a etapa falhou, com o rótulo de quem já o define: o TimelineView::Error, o motivo do descarte da
  # ação (AgentActionView) ou o detalhe do turno não aberto. nil se a etapa não falhou.
  def failure_label
    return if kind == :outbox_item
    return error.origin_label if error
    return agent_action&.rejection_reason_label if kind == :discarded

    detail if kind == :turn_not_opened
  end
end
