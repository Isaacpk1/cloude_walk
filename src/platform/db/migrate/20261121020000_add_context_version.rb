# Bloco 06: versão do contexto no atendimento e prova do contexto enviado em cada turno
# (07, seção 3.4 e 4; RN-49, RN-55, RF-33).
class AddContextVersion < ActiveRecord::Migration[8.1]
  def change
    # Sobe 1 em toda gravação que muda o contexto do próximo turno, com a linha travada.
    add_column :tickets, :context_version, :integer, null: false, default: 0
    add_check_constraint :tickets, "context_version >= 0", name: "tickets_context_version_check"

    # Versão e SHA-256 do JSON canônico do contexto enviado. Nulos só em turnos de antes do bloco 06.
    add_column :ai_turns, :context_version, :integer
    add_column :ai_turns, :context_digest, :string
    add_check_constraint :ai_turns, "context_digest IS NULL OR context_digest ~ '^sha256:[0-9a-f]{64}$'",
                         name: "ai_turns_context_digest_check"
  end
end
