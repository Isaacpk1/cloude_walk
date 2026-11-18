# Um evento da linha do tempo. A duração sai dos tempos registrados, nunca de um valor digitado.
class TimelineView::Event < Data.define(:kind, :started_at, :finished_at, :ticket_id, :seq, :turn, :trace_id, :detail, :source)
  LABELS = {
    received: "Recebimento",
    persisted: "Gravação",
    intentional_wait: "Espera intencional (janela de agrupamento)",
    published: "Publicação no broker",
    agent_run: "Execução do agente",
    applied: "Aplicação da resposta",
    discarded: "Descarte da resposta",
    escalated: "Escalação",
    assigned: "Atribuição",
    delivered: "Entrega ao canal"
  }.freeze

  def self.ms_between(from, to) = ((to - from) * 1000).round

  def initialize(kind:, started_at:, finished_at:, **rest)
    raise ArgumentError, "kind desconhecido: #{kind}" unless LABELS.key?(kind)
    if finished_at && finished_at < started_at
      raise ArgumentError, "finished_at (#{finished_at}) antes de started_at (#{started_at})"
    end

    super
  end

  def label = LABELS.fetch(kind)
  def duration_ms = finished_at && self.class.ms_between(started_at, finished_at)
  def intentional_wait? = kind == :intentional_wait
end
