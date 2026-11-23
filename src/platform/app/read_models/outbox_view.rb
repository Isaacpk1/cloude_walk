# Um item do outbox ligado ao atendimento, no formato de leitura do painel (ROADMAP 09: "mostrar tentativas e
# desfecho do evento"; RF-34, RNF-16). `attempts_count` é outbox_events.attempts (cada reserva do item soma
# uma); `attempts` são os registros da auditoria, em ordem: cada tentativa com o erro (TimelineView::Error, o
# mesmo da linha do tempo) e a próxima tentativa, mais o reoferecimento pela recuperação e o encerramento por
# obsolescência (bloco 09). `outcome` é o desfecho do item até agora.
class OutboxView < Data.define(:id, :event_type, :turn, :seq, :delivery_id, :attempts_count, :outcome, :outcome_detail,
                               :attempts, :last_error, :next_attempt_at, :created_at, :completed_at, :recovered_count,
                               :trace_id)
  # Uma entrada da lista: tentativa (number), reoferecimento ou encerramento (number nil).
  Attempt = Data.define(:number, :at, :duration_ms, :error, :next_attempt_at, :result_label)

  OUTCOMES = {
    published: "Publicado",
    delivered: "Entregue",
    discarded: "Descartado",
    cancelled: "Cancelada",
    closed_obsolete: "Encerrado como obsoleto",
    failed: "Falhou definitivo",
    reconciliation: "Em conciliação",
    completed: "Concluído",
    recovered: "Reoferecido pela recuperação",
    retrying: "Em retentativa",
    in_progress: "Tentativa em curso",
    pending: "Aguardando"
  }.freeze

  TYPES = {
    "agent.event" => "Publicação do turno",
    "delivery.requested" => "Entrega da saída",
    "handoff.requested" => "Pedido de handoff",
    "turn.timeout" => "Prazo do turno",
    "cycle.timeout" => "Teto do ciclo",
    "progress.notice" => "Aviso de progresso"
  }.freeze

  def initialize(attempts:, outcome:, outcome_detail: nil, **rest)
    raise ArgumentError, "desfecho desconhecido: #{outcome}" unless OUTCOMES.key?(outcome)

    super(attempts: attempts.freeze, outcome:, outcome_detail:, **rest)
  end

  def outcome_label = [ OUTCOMES.fetch(outcome), outcome_detail ].compact.join(": ")
  def summary = "#{attempts_count} #{attempts_count == 1 ? 'tentativa' : 'tentativas'} · #{outcome_label}"
  def open? = completed_at.nil?
  def reconciliation? = outcome == :reconciliation

  def type_label
    head = TYPES.fetch(event_type, event_type)
    return "#{head} #{turn}" if event_type == "agent.event" && turn
    return "#{head} seq #{seq}" if event_type == "delivery.requested" && seq

    head
  end
end
