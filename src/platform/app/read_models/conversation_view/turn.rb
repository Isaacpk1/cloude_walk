# Um registro de `ai_turns` (07, seção 3.4): o que a IA recebeu e o que aconteceu com a resposta.
# `covered_seqs` são as mensagens do cliente que entraram no contexto do turno.
class ConversationView::Turn < Data.define(
  :number, :status, :covered_seqs, :context_until_seq, :assignment_version, :event_id, :action, :note, :tool_calls
)
  STATUS_LABELS = {
    "eligible" => "Elegível", "applied" => "Aplicado", "superseded" => "Superado", "expired" => "Expirado"
  }.freeze

  def initialize(status:, covered_seqs:, tool_calls: [], **rest)
    raise ArgumentError, "status de turno desconhecido: #{status}" unless STATUS_LABELS.key?(status)

    super(status:, covered_seqs: covered_seqs.sort.freeze, tool_calls: tool_calls.freeze, **rest)
  end

  def status_label = STATUS_LABELS.fetch(status)
  def superseded? = status == "superseded"
  def applied? = status == "applied"
end
