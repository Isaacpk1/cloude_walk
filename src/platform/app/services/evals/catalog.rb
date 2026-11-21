# Cenários de eval conhecidos (ADR-023). Stub do painel (bloco 07, S3): na integração vale o catálogo do
# executor, com a mesma assinatura: `scenarios` → [{ name:, title:, description: }].
module Evals
  module Catalog
    SCENARIOS = [
      {
        name: "corrida-3s", title: "Corrida dos 3 s",
        description: "A mensagem 2 chega aos 3 s, com o turno 1 no agente; a resposta do turno 1 aos 3,5 s é rejeitada " \
                     "e só o turno 2, com as mensagens 1 e 2, responde ao cliente (RN-55, RN-56; 07, seção 3.4)."
      }
    ].freeze

    module_function

    def scenarios = SCENARIOS
  end
end
