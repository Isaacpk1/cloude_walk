# Rótulos da prioridade do atendimento (RN-12: crítica > alta > média > baixa). Sem triagem ainda (bloco 11), o caso
# vale como média (RN-13): a fila ordena assim e a tela diz que é o padrão.
module ConversationView::Priority
  LABELS = { "critica" => "crítica", "alta" => "alta", "media" => "média", "baixa" => "baixa" }.freeze
  UNTRIAGED = "média (sem triagem, RN-13)".freeze

  module_function

  def label(priority) = priority ? LABELS.fetch(priority, priority) : UNTRIAGED
  def short_label(priority) = LABELS.fetch(priority || "media", priority)

  # "subiu: média → alta (RN-41)", ou nil quando não subiu.
  def raise_label(from, to) = from == to || to.nil? ? nil : "subiu: #{short_label(from)} → #{short_label(to)} (RN-41)"
end
