# Responsável por um atendimento: o bot, um analista ou a fila enquanto espera atribuição (RN-27).
class ConversationView::Participant < Data.define(:name, :kind)
  KIND_LABELS = { "bot" => "IA", "human" => "Analista", "queue" => "Fila" }.freeze

  def kind_label = KIND_LABELS.fetch(kind, kind)
end
