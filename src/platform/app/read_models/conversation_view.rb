# Formato de leitura estável da tela de conversa (ROADMAP, "Manter um formato de leitura estável").
# A tela só conhece esta representação. Hoje ela é preenchida por SyntheticConversations;
# a partir do bloco 02, um adaptador lê tickets, messages, ai_turns, deliveries e audit_events
# (07, seção 4) e preenche os mesmos campos.
class ConversationView < Data.define(
  :id, :ticket_id, :brand_slug, :brand_name, :customer_name, :channel, :state, :title,
  :assignee, :assignment_version, :latest_customer_seq, :messages, :turns, :escalations, :source
)
  def initialize(messages:, turns:, escalations:, **rest)
    super(
      messages: messages.sort_by(&:seq).freeze,
      turns: turns.sort_by(&:number).freeze,
      escalations: escalations.sort_by(&:occurred_at).freeze,
      **rest
    )
  end

  def messages_in(turn) = messages.select { turn.covered_seqs.include?(_1.seq) }
  def turns_covering(seq) = turns.select { _1.covered_seqs.include?(seq) }
  def superseded_turns = turns.select(&:superseded?)
  def covers_latest_customer_seq?(turn) = turn.context_until_seq >= latest_customer_seq

  def first_customer_message = messages.find(&:customer?)
  def last_message = messages.last
end
