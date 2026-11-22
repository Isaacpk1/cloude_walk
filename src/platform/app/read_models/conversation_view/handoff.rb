# Handoff do atendimento para a fila humana (ROADMAP 08; RN-46, RF-36, RNF-18; 07, seção 3.2), no formato da interface
# combinada dos blocos 08 e 09 (item 1). `state`: :requested (handoff.requested gravado, o worker ainda não processou),
# :escalated (ticket.escalated: fila padrão da marca, assignment_version + 1, ciclo da IA encerrado) ou :discarded
# (handoff.discarded, com `discard_reason`). `reason` e `source` são os do pedido. `waited_ms`: da gravação da primeira
# mensagem pendente até a entrada na fila humana (RNF-18: até T + 2 s). `cancelled_deliveries`: as saídas pending da
# atribuição antiga à IA canceladas pelo handoff (CancelledDelivery).
# Bloco 10: `queue_version` e `queue_kind` (escalation | default | missing; RF-42), `priority` (a do caso agora) e
# `priority_from`/`priority_to` (a subida da RN-41 nesta escalação, ou nil), `summary` (ConversationView::HandoffSummary;
# RN-39, RN-40) e `transfer_notice` (ConversationView::TransferNotice; RN-42), nil antes da escalação.
class ConversationView::Handoff < Data.define(:state, :reason, :source, :turn, :first_pending_seq, :requested_at,
                                              :resolved_at, :discard_reason, :from_assignment_version,
                                              :to_assignment_version, :queue_id, :queue_name, :waited_ms,
                                              :cancelled_deliveries, :trace_id, :queue_version, :queue_kind,
                                              :priority, :priority_from, :priority_to, :summary, :transfer_notice)
  CancelledDelivery = Data.define(:delivery_id, :seq, :kind)

  REASONS = {
    "prazo_do_turno" => "Prazo do turno vencido (20 s desde a abertura, RN-46)",
    "teto_do_ciclo" => "Teto do ciclo vencido (60 s desde a primeira mensagem pendente, RN-46)",
    "publicacao_falhou" => "Publicação do turno falhou de forma definitiva (RN-46)",
    "contexto_excede_limite" => "Contexto excede o limite do turno (RN-49)",
    "falha_de_integracao" => "Falha de integração: evento do turno na DLQ (RN-45)",
    "limite_de_trocas" => "Limite de trocas com a IA sem resolver (RN-33)",
    "pedido_do_cliente" => "Pedido explícito do cliente (RN-34)",
    "decisao_do_agente" => "Decisão do agente de IA: ação escalate (RN-33)"
  }.freeze

  SOURCES = {
    "scheduler" => "Scheduler: prazo vencido no Postgres (ADR-016)",
    "outbox" => "Outbox: publicação para o agente",
    "turns" => "Abertura do turno",
    "dlq" => "DLQ da plataforma",
    "ingestion" => "Ingestão: mensagem do cliente",
    "agent" => "Agente de IA: ação do turno"
  }.freeze

  DISCARD_REASONS = {
    "atribuicao_mudou" => "o atendimento mudou de responsável desde o pedido",
    "fora_da_ia" => "o caso já não estava com a IA",
    "ja_escalado" => "o caso já estava na fila humana"
  }.freeze

  STATES = %i[requested escalated discarded].freeze

  def initialize(state:, cancelled_deliveries: [], queue_version: nil, queue_kind: nil, priority: nil, priority_from: nil,
                 priority_to: nil, summary: nil, transfer_notice: nil, **rest)
    raise ArgumentError, "estado do handoff desconhecido: #{state}" unless STATES.include?(state)

    super(state:, cancelled_deliveries: cancelled_deliveries.freeze, queue_version:, queue_kind:, priority:, priority_from:,
          priority_to:, summary:, transfer_notice:, **rest)
  end

  def queue_label = HumanQueue::Entry.queue_label(queue_name, queue_version, queue_kind)
  def priority_label = ConversationView::Priority.label(priority)
  def priority_raise_label = priority_to && ConversationView::Priority.raise_label(priority_from, priority_to)

  def self.reason_label(reason) = reason && REASONS.fetch(reason, reason)
  def self.source_label(source) = source && SOURCES.fetch(source, source)
  def self.discard_reason_label(reason) = reason && DISCARD_REASONS.fetch(reason, reason)

  def reason_label = self.class.reason_label(reason)
  def source_label = self.class.source_label(source)
  def discard_reason_label = self.class.discard_reason_label(discard_reason)
  def escalated? = state == :escalated

  def headline
    case state
    when :escalated then "Na fila humana: #{queue_name || 'fila padrão'}"
    when :requested then "Handoff pedido: aguardando o worker"
    else "Pedido de handoff descartado"
    end
  end
end
