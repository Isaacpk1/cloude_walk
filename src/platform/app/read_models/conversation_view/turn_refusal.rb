# Recusa terminal do turno da última mensagem (RN-49, RN-46; 07, seção 3.4): o Turns::Open não abriu o turno
# por um motivo que nenhuma volta do scheduler muda (Turns::Open::TERMINAL_REASONS) e o ciclo espera o handoff
# (bloco 10). Ocupa o lugar da fase de agrupamento. `pending_seqs`: as mensagens que ficaram sem turno;
# `pending_chars` e `limit` no contexto_excede_limite; `deadline_at` (teto do ciclo) no prazo_vencido;
# `violations` (ponteiros JSON) no contrato. Bloco 08: `handoff_reason` é o motivo do handoff.requested gravado depois
# da recusa; sem ele, o handoff continua pendente (bloco 10).
class ConversationView::TurnRefusal < Data.define(:reason, :pending_seqs, :pending_chars, :limit, :deadline_at,
                                                  :violations, :occurred_at, :trace_id, :handoff_reason)
  def initialize(handoff_reason: nil, **rest) = super

  def headline
    return "Turno não aberto: #{reason} — handoff pendente (bloco 10)" unless handoff_reason

    "Turno não aberto: #{reason} — handoff pedido (#{ConversationView::Handoff.reason_label(handoff_reason)})"
  end

  def detail
    case reason
    when "contexto_excede_limite"
      "#{pending_chars} caracteres pendentes, acima do limite de #{limit} (RN-49)"
    when "prazo_vencido"
      "teto do ciclo #{deadline_at && PanelClock.format(deadline_at, precise: true)} vencido antes de o turno abrir (RN-46)"
    when "contrato"
      "evento do turno fora do contrato agent_inbound (#{Array(violations).join(', ')}); publicação definitivamente falha (RN-46)"
    else
      "atendimento sem teto do ciclo (ai_deadline_at) gravado"
    end
  end
end
