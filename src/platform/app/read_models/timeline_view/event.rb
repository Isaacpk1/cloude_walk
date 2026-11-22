# Um evento da linha do tempo. A duração sai dos tempos registrados, nunca de um valor digitado.
# `error` (TimelineView::Error) fica preenchido nas etapas que falharam: a tela mostra a origem ao
# escolher o evento (ROADMAP 03). `agent_action` (AgentActionView) fica preenchido nos eventos da ação
# recebida do agente: a tela mostra as consultas e a ação ao escolher o evento (ROADMAP 04). `cause`
# (TimelineView::Cause) fica preenchido nos prazos, no turno expirado, no handoff e no aviso de progresso (bloco 08):
# a tela mostra o gatilho, o motivo e o desfecho ao escolher o evento.
class TimelineView::Event < Data.define(:kind, :started_at, :finished_at, :ticket_id, :seq, :turn, :trace_id, :detail,
                                        :source, :error, :agent_action, :cause)
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
    progress_scheduled: "Aviso de progresso agendado",
    progress_sent: "Aviso de progresso enviado",
    progress_discarded: "Aviso de progresso descartado"
  }.freeze

  def self.ms_between(from, to) = ((to - from) * 1000).round

  def initialize(kind:, started_at:, finished_at:, error: nil, agent_action: nil, cause: nil, **rest)
    raise ArgumentError, "kind desconhecido: #{kind}" unless LABELS.key?(kind)
    if finished_at && finished_at < started_at
      raise ArgumentError, "finished_at (#{finished_at}) antes de started_at (#{started_at})"
    end

    super(kind:, started_at:, finished_at:, error:, agent_action:, cause:, **rest)
  end

  def label = LABELS.fetch(kind)
  def duration_ms = finished_at && self.class.ms_between(started_at, finished_at)
  def intentional_wait? = kind == :intentional_wait
  def error? = !error.nil?
end
