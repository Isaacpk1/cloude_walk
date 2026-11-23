# Parâmetros da triagem num lugar só (RF-12; 06, RN-11 a RN-13 e RN-28; 07, seção 3.1, passo 2).
#
#   policy = Triage::Policy.for(brand)
#   policy.categories                    # RN-11: lista da marca
#   policy.keywords.fetch(brand.locale)  # categoria => palavras, sem acento nem maiúsculas
#   policy.impact.fetch(brand.locale)    # RN-12: prioridade => palavras de impacto
#   policy.tags.fetch(brand.locale)      # RF-10: tag => palavras
#   policy.human_only?(category)         # RN-28: vai à fila de escalas sem passar pela IA
#
# Hoje toda marca usa os padrões, como o Handoff::Policy. No bloco 12, `for` passa a ler a configuração versionada
# da marca (lista de categorias, palavras por idioma, categorias somente humanas); quem chama não muda.
module Triage
  Policy = Data.define(:categories, :keywords, :base_priority, :impact, :tags, :human_only_categories,
                       :fallback_category, :fallback_priority) do
    def human_only?(category) = human_only_categories.include?(category)

    # RN-12: crítica > alta > média > baixa.
    def highest(priorities) = priorities.compact.min_by { Triage::Policy::PRIORITIES.index(_1) }

    def keywords_for(locale) = keywords.fetch(locale, {})
    def impact_for(locale) = impact.fetch(locale, {})
    def tags_for(locale) = tags.fetch(locale, {})
  end

  class Policy
    PRIORITIES = %w[critica alta media baixa].freeze
    CATEGORIES = %w[transacoes_e_pagamentos repasses pix credito conta_digital maquininha cadastro outros].freeze

    # Palavras sem acento, em minúsculas e sem apóstrofo ("won't" → "wont"), como o texto chega ao Classify.
    # A ordem das categorias desempata: as mais específicas primeiro, transações (a mais genérica) por último.
    PT_BR_KEYWORDS = {
      "maquininha" => %w[maquininha maquina pos smartpos bobina leitor],
      "pix" => [ "pix", "chave pix", "qr code" ],
      "repasses" => %w[repasse repasses antecipacao recebivel recebiveis liquidacao],
      "credito" => [ "emprestimo", "credito pessoal", "limite de credito", "capital de giro", "financiamento" ],
      "conta_digital" => [ "conta digital", "saldo", "extrato", "ted", "transferencia", "boleto" ],
      "cadastro" => [ "cadastro", "cadastrais", "e-mail", "email", "senha", "telefone", "endereco", "cnpj",
                      "conta bancaria" ],
      "transacoes_e_pagamentos" => [ "venda", "vendas", "vender", "transacao", "transacoes", "pagamento", "cobranca",
                                     "taxa", "taxas", "estorno", "chargeback", "link de pagamento", "parcelado" ]
    }.freeze

    EN_KEYWORDS = {
      "maquininha" => [ "card machine", "card reader", "terminal", "pos" ],
      "pix" => [ "pix", "pix key", "qr code" ],
      "repasses" => %w[payout payouts settlement settlements prepayment receivables],
      "credito" => [ "loan", "credit line", "credit limit", "financing", "working capital" ],
      "conta_digital" => [ "digital account", "balance", "statement", "bank transfer", "wire", "bill payment" ],
      "cadastro" => [ "registration", "sign up", "e-mail", "email", "password", "phone number", "address",
                      "account details", "bank account" ],
      "transacoes_e_pagamentos" => [ "sale", "sales", "sell", "transaction", "transactions", "payment", "charge",
                                     "fee", "fees", "refund", "chargeback", "payment link", "installments" ]
    }.freeze

    # RN-12: crítica é o lojista impedido de vender ou receber; alta é dinheiro pendente ou divergente.
    PT_BR_IMPACT = {
      "critica" => [ "nao liga", "parada", "parado", "parou", "travou", "travada", "nao funciona", "nao passa",
                     "nao consigo vender", "nao consigo receber", "bloqueada", "bloqueado", "fora do ar" ],
      "alta" => [ "nao caiu", "nao recebi", "nao recebido", "nao chegou", "nao entrou", "valor errado",
                  "valor diferente", "divergente", "divergencia", "cobrado duas vezes", "cobranca indevida", "sumiu" ]
    }.freeze

    EN_IMPACT = {
      "critica" => [ "wont turn on", "doesnt turn on", "not turning on", "stopped working", "not working",
                     "cant sell", "cannot sell", "cant receive", "cannot receive", "blocked", "frozen" ],
      "alta" => [ "not received", "havent received", "didnt receive", "never received", "didnt arrive",
                  "hasnt arrived", "missing", "wrong amount", "charged twice", "double charged" ]
    }.freeze

    # RF-10: tags que ajudam a regra de roteamento (campo `tags`, operador `contains`) e o analista.
    PT_BR_TAGS = {
      "urgente" => %w[urgente urgencia emergencia],
      "reclamacao" => [ "procon", "reclame aqui", "reclamacao", "advogado", "processar" ],
      "fraude" => [ "fraude", "golpe", "nao reconheco", "clonado", "clonada", "invadida", "invadiram" ]
    }.freeze

    EN_TAGS = {
      "urgente" => %w[urgent asap emergency],
      "reclamacao" => %w[complaint lawyer sue],
      "fraude" => [ "fraud", "scam", "dont recognize", "cloned", "hacked" ]
    }.freeze

    DEFAULT = new(
      categories: CATEGORIES,
      keywords: { "pt-BR" => PT_BR_KEYWORDS, "en" => EN_KEYWORDS }.freeze,
      # RN-12: baixa é cadastro ou informação geral; o resto parte de média (dúvida financeira). RN-13: outros, média.
      base_priority: CATEGORIES.index_with { "media" }.merge("cadastro" => "baixa").freeze,
      impact: { "pt-BR" => PT_BR_IMPACT, "en" => EN_IMPACT }.freeze,
      tags: { "pt-BR" => PT_BR_TAGS, "en" => EN_TAGS }.freeze,
      # RN-28 com a RN-35: alterar cadastro (e-mail, senha, conta bancária) é exclusivo de humanos. A IA só poderia
      # escalar, depois de gastar um ciclo (até 60 s, RN-46) com o cliente esperando.
      human_only_categories: %w[cadastro].freeze,
      fallback_category: "outros",
      fallback_priority: "media"
    )

    def self.for(_brand) = DEFAULT
  end
end
