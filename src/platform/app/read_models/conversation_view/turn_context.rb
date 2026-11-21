# O contexto que a IA recebeu num turno (RN-49, RN-55; 07, seção 3.4, "Contexto completo, de forma
# verificável"), lido de ai_turns.context: as mensagens pendentes que entraram no turno, separadas do
# histórico, o context_version e a conferência do digest. `check`: :verified (o digest recalculado com
# Turns::ContextDigest bate com ai_turns.context_digest), :diverged (não bate: o contexto gravado não é o
# que foi enviado) ou :missing (turno sem digest, anterior ao bloco 06).
class ConversationView::TurnContext < Data.define(:pending_messages, :history, :context_version, :recorded_digest,
                                                  :computed_digest)
  Entry = Data.define(:seq, :author, :text)

  CHECK_LABELS = {
    verified: "Contexto conferido", diverged: "Contexto diverge do gravado", missing: "Turno anterior ao bloco 06"
  }.freeze

  def self.from(record)
    context = record.context || {}
    new(pending_messages: entries(context["pending_messages"], author: "customer"), history: entries(context["history"]),
        context_version: record.context_version, recorded_digest: record.context_digest,
        computed_digest: Turns::ContextDigest.call(context))
  end

  def self.entries(items, author: nil)
    Array(items).map { Entry.new(seq: _1["seq"], author: _1["author"] || author, text: _1["text"].to_s) }.freeze
  end

  def check
    return :missing if recorded_digest.nil?

    recorded_digest == computed_digest ? :verified : :diverged
  end

  def check_label = CHECK_LABELS.fetch(check)
  def short_digest = recorded_digest&.delete_prefix("sha256:")&.first(12)
end
