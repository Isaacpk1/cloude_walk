# Prazos do atendimento (ROADMAP 08; RN-46, RN-57, ADR-020; 07, seção 3.4): com o ciclo pendente com a IA, o teto do
# ciclo (`ai_deadline_at`, 60 s desde a primeira pendente, sem reiniciar), o prazo do turno atual (`ai_turns.deadline_at`,
# 20 s desde a abertura, limitado ao teto) e o aviso de progresso do ciclo (`progress`, ConversationView::ProgressNotice).
# `remaining_ms` e `turn_remaining_ms` são negativos depois do vencimento. Sem ciclo pendente (`pending` falso), só o
# aviso do último ciclo aparece, para o motivo do cancelamento ou do descarte continuar visível.
class ConversationView::Deadlines < Data.define(:pending, :first_pending_seq, :first_pending_at, :ai_deadline_at,
                                                :remaining_ms, :turn, :turn_deadline_at, :turn_remaining_ms, :progress)
  def overdue = !remaining_ms.nil? && remaining_ms.negative?
  def turn_overdue = !turn_remaining_ms.nil? && turn_remaining_ms.negative?
  def turn_limited_by_cycle = !turn_deadline_at.nil? && !ai_deadline_at.nil? && turn_deadline_at >= ai_deadline_at

  def remaining_text = self.class.remaining_text(remaining_ms)
  def turn_remaining_text = self.class.remaining_text(turn_remaining_ms)

  def self.remaining_text(ms)
    return if ms.nil?
    return "vence agora" if ms.zero?

    ms.positive? ? "faltam #{seconds(ms)} s" : "vencido há #{seconds(-ms)} s"
  end

  def self.seconds(ms) = format("%.1f", ms / 1000.0).tr(".", ",")
end
