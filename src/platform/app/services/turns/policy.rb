# Tempos do atendimento pela IA num lugar só (ADR-020; 06, parâmetros).
#
#   policy = Turns::Policy.for(brand)
#   policy.window_for("chat")                      # janela de agrupamento (RN-55)
#   policy.turn_deadline_at(opened_at:, cycle_deadline_at:)
#
# Hoje toda marca usa os padrões. No bloco 12, `for` passa a ler a configuração versionada da marca,
# editada pelo supervisor e com limites; quem chama não muda. Os prazos já ficam gravados no
# atendimento e no turno, então mudar a configuração só afeta ciclos novos.
module Turns
  Policy = Data.define(:windows, :ceiling, :turn_deadline, :cycle_deadline, :progress_notice) do
    # Canal desconhecido é erro: uma janela padrão esconderia um canal novo sem parâmetro definido.
    def window_for(channel) = windows.fetch(channel)

    # ADR-020: 20 s desde a abertura do turno, sem passar do teto do ciclo.
    def turn_deadline_at(opened_at:, cycle_deadline_at:) = [ opened_at + turn_deadline, cycle_deadline_at ].min
  end

  class Policy
    DEFAULT = new(
      windows: { "chat" => 1.5.seconds, "whatsapp" => 1.5.seconds, "email" => 0.seconds }.freeze, # RN-55
      ceiling: 4.seconds,          # RN-55: teto da janela desde a primeira mensagem pendente
      turn_deadline: 20.seconds,   # RN-46, ADR-020: prazo de cada turno
      cycle_deadline: 60.seconds,  # RN-46, ADR-020: teto do ciclo, não reinicia
      progress_notice: 15.seconds  # RN-57
    )

    def self.for(_brand) = DEFAULT
  end
end
