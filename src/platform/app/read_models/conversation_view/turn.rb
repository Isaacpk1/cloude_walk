# Um registro de `ai_turns` (07, seção 3.4): o que a IA recebeu e o que aconteceu com a resposta.
# `covered_seqs` são as mensagens do cliente que entraram no contexto do turno. `agent_action`
# (AgentActionView) é a ação recebida do agente, quando houver (bloco 04). `stages`
# (ConversationView::TurnStages) são os estágios ação recebida, resposta aplicada e entregue (bloco 05).
class ConversationView::Turn < Data.define(
  :number, :status, :covered_seqs, :context_until_seq, :assignment_version, :event_id, :action, :note, :tool_calls, :agent_action, :stages
)
  STATUS_LABELS = {
    "eligible" => "Elegível", "applied" => "Aplicado", "superseded" => "Superado", "expired" => "Expirado"
  }.freeze

  def initialize(status:, covered_seqs:, tool_calls: [], agent_action: nil, stages: nil, **rest)
    raise ArgumentError, "status de turno desconhecido: #{status}" unless STATUS_LABELS.key?(status)

    super(status:, covered_seqs: covered_seqs.sort.freeze, tool_calls: tool_calls.freeze, agent_action:, stages:, **rest)
  end

  def status_label = STATUS_LABELS.fetch(status)
  def superseded? = status == "superseded"
  def applied? = status == "applied"
  def eligible? = status == "eligible"

  # Sem ação recebida: o turno ainda elegível espera o agente; encerrado, ficou sem resposta.
  def response_state_label
    return agent_action.outcome_label if agent_action

    eligible? ? "Aguardando resposta do agente" : "Sem resposta do agente"
  end
end
