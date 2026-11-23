# Ação recebida do agente para um turno (ROADMAP 04; 07, seção 5.3; RF-31, RF-32, RN-37), no formato
# de leitura do painel. Vem de ai_turns.response (a primeira ação recebida para o turno) ou do `data`
# da auditoria agent_action.applied/rejected. O texto da resposta e os resultados das consultas vêm de
# fora: a tela só os mostra com o escape padrão do ERB.
class AgentActionView < Data.define(
  :event_id, :action, :reply_text, :escalation_reason, :escalation_summary, :resolution_reason, :resolution_text,
  :tool_calls, :model, :version, :config_hash, :agent_ms, :outcome, :rejection_reason
)
  ToolCall = Data.define(:tool, :args, :result, :duration_ms)

  ACTION_LABELS = { "reply" => "Resposta ao cliente", "escalate" => "Escalação para humano", "resolve" => "Encerramento" }.freeze
  OUTCOME_LABELS = { applied: "Aplicada", rejected: "Descartada", received: "Recebida, sem desfecho registrado" }.freeze
  REJECTION_REASONS = {
    "turno_superado" => "Turno superado por mensagem nova do cliente (RN-56)",
    "in_reply_to_divergente" => "in_reply_to diferente do event_id enviado no turno (RN-56)",
    "atribuicao_mudou" => "O atendimento mudou de responsável desde o turno (RN-56)",
    "fora_da_ia" => "O atendimento não está mais com a IA",
    "prazo_vencido" => "Prazo da IA vencido (RN-46)",
    "turno_nao_elegivel" => "Turno já encerrado: não aceita outra ação final",
    "marca_divergente" => "Marca da ação diferente da marca do atendimento (ADR-014)",
    "turno_inexistente" => "Turno não encontrado para o atendimento",
    "contexto_divergente" => "context_until_seq diferente do enviado no turno (RN-56)",
    "ciclo_encerrado" => "Ciclo da IA já encerrado: não há mensagem pendente (RN-46)",
    "handoff_pedido" => "Handoff já pedido para o atendimento: a IA não responde mais (RN-45, RN-46)"
  }.freeze
  SUMMARY_FIELDS = %w[problema dados_cliente acoes_tomadas motivo pendente].freeze

  # payload: a ação no contrato agent_outbound (ou o `data` da auditoria, que repete os mesmos campos).
  def self.from(payload, outcome:, rejection_reason: nil)
    agent = payload["agent"] || {}
    new(
      event_id: payload["event_id"], action: payload["action"], reply_text: payload.dig("reply", "text"),
      escalation_reason: payload.dig("escalation", "reason"), escalation_summary: payload.dig("escalation", "summary") || {},
      resolution_reason: payload.dig("resolution", "reason"), resolution_text: payload.dig("resolution", "text"),
      tool_calls: Array(payload["tool_calls"]).map { tool_call(_1) },
      model: agent["model"], version: agent["version"], config_hash: agent["config_hash"],
      agent_ms: payload.dig("timing", "agent_ms"), outcome:, rejection_reason:
    )
  end

  def self.tool_call(call)
    ToolCall.new(tool: call["tool"], args: call["args"] || {}, result: call["result"], duration_ms: call["duration_ms"])
  end
  private_class_method :tool_call

  def initialize(outcome:, **rest)
    raise ArgumentError, "desfecho desconhecido: #{outcome}" unless OUTCOME_LABELS.key?(outcome)

    super
  end

  def action_label = ACTION_LABELS.fetch(action, action)
  def outcome_label = OUTCOME_LABELS.fetch(outcome)
  def rejection_reason_label = rejection_reason && REJECTION_REASONS.fetch(rejection_reason, rejection_reason)
  def short_config_hash = config_hash&.first(12)
  def agent_label = [ model, version ].compact.join(" ")
  def tool_calls_text = tool_calls.map { |call| call.duration_ms ? "#{call.tool} (#{call.duration_ms} ms)" : call.tool }.join(", ")
  def applied? = outcome == :applied
  def rejected? = outcome == :rejected
end
