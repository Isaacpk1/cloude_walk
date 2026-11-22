# Aviso de progresso de um ciclo (RN-57; 07, seção 3.4): um por ciclo, aos 15 s desde a primeira mensagem pendente.
# `state`: :scheduled (previsto em `due_at`; `scheduled_at` e `delay_ms` quando o scheduler já registrou a ação),
# :sent (saída gravada: `delivery_id`, `seq` e o status da entrega kind "progress"), :cancelled (entrega cancelada antes
# do envio, com `reason`: resposta_aplicada ou handoff) ou :discarded (o worker descartou, com `reason`).
# `overdue`: previsto, o horário passou e o scheduler ainda não registrou a ação.
class ConversationView::ProgressNotice < Data.define(:state, :first_pending_seq, :due_at, :scheduled_at, :delay_ms,
                                                     :occurred_at, :delivery_id, :seq, :delivery_status, :reason,
                                                     :overdue, :trace_id)
  STATES = { scheduled: "Previsto", sent: "Enviado", cancelled: "Cancelado", discarded: "Descartado" }.freeze

  REASONS = {
    "resposta_aplicada" => "a resposta da IA foi aplicada antes do envio do aviso (07, seção 3.4)",
    "handoff" => "o caso foi para a fila humana antes do envio do aviso (07, seção 3.2)",
    "eval" => "atendimento de eval: nada sai para o canal (ADR-023)",
    "ciclo_encerrado" => "o ciclo já tinha sido encerrado quando o aviso venceu",
    "ciclo_mudou" => "o ciclo mudou desde o registro do aviso",
    "fora_da_ia" => "o caso já não estava com a IA",
    "atribuicao_mudou" => "o atendimento mudou de responsável desde o registro do aviso"
  }.freeze

  def initialize(state:, scheduled_at: nil, delay_ms: nil, occurred_at: nil, delivery_id: nil, seq: nil,
                 delivery_status: nil, reason: nil, overdue: false, trace_id: nil, **rest)
    raise ArgumentError, "estado do aviso desconhecido: #{state}" unless STATES.key?(state)

    super
  end

  def state_label = STATES.fetch(state)
  def reason_label = reason && REASONS.fetch(reason, reason)
  def delivery_status_label = delivery_status && ConversationView::Message::DELIVERY_LABELS.fetch(delivery_status, delivery_status)
end
