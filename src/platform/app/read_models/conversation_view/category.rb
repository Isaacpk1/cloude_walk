# Rótulos legíveis das categorias da triagem (RN-11). Categoria fora da lista (configurada depois por marca, bloco 12)
# aparece como foi gravada.
module ConversationView::Category
  LABELS = {
    "transacoes_e_pagamentos" => "transações e pagamentos", "repasses" => "repasses", "pix" => "Pix",
    "credito" => "crédito", "conta_digital" => "conta digital", "maquininha" => "maquininha", "cadastro" => "cadastro",
    "outros" => "outros"
  }.freeze

  module_function

  def label(category) = category && LABELS.fetch(category, category)
end
