# Formato de leitura estável da tela de conversa (ROADMAP, "Manter um formato de leitura estável").
# A tela só conhece esta representação. Hoje ela é preenchida por SyntheticConversations;
# a partir do bloco 02, um adaptador lê tickets, messages, ai_turns, deliveries e audit_events
# (07, seção 4) e preenche os mesmos campos. `grouping` (ConversationView::Grouping) é a fase de
# agrupamento enquanto o turno da última mensagem não abriu (bloco 06); nil fora dela. `turn_refusal`
# (ConversationView::TurnRefusal) é a recusa terminal desse turno, no lugar do agrupamento; nil fora dela.
# Bloco 08: `deadlines` (ConversationView::Deadlines) são os prazos do ciclo com a IA e o aviso de progresso;
# `handoff` (ConversationView::Handoff) é o último pedido de handoff e o seu desfecho; nil fora deles.
# `reconciliations` (ConversationView::Reconciliation) são as entregas em conciliação, em destaque (bloco 09).
class ConversationView < Data.define(
  :id, :ticket_id, :brand_slug, :brand_name, :customer_name, :channel, :state, :title,
  :assignee, :assignment_version, :latest_customer_seq, :messages, :turns, :escalations, :source, :grouping,
  :turn_refusal, :deadlines, :handoff, :reconciliations
)
  def initialize(messages:, turns:, escalations:, grouping: nil, turn_refusal: nil, deadlines: nil, handoff: nil,
                 reconciliations: [], **rest)
    super(
      grouping:, turn_refusal:, deadlines:, handoff:, reconciliations: reconciliations.freeze,
      messages: messages.sort_by(&:seq).freeze,
      turns: turns.sort_by(&:number).freeze,
      escalations: escalations.sort_by(&:occurred_at).freeze,
      **rest
    )
  end

  # Stream do Turbo da conversa (bloco 10): o AuditEvent pede a recarga quando o caso escala ou o resumo chega.
  def self.stream_for(brand_slug, ticket_id) = [ :conversation, brand_slug, ticket_id.to_s ]

  def stream = self.class.stream_for(brand_slug, ticket_id)

  def messages_in(turn) = messages.select { turn.covered_seqs.include?(_1.seq) }
  def turns_covering(seq) = turns.select { _1.covered_seqs.include?(seq) }
  def superseded_turns = turns.select(&:superseded?)
  def covers_latest_customer_seq?(turn) = turn.context_until_seq >= latest_customer_seq

  def first_customer_message = messages.find(&:customer?)
  def last_message = messages.last
end
