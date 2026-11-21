# Grava uma execução de eval no formato combinado do bloco 07 (ADR-023): checagens da corrida-3s com a
# evidência { turn, seq }. O painel não roda o executor: lê o que estiver em eval_runs.
module EvalRunHelpers
  RACE_CHECKS = [
    [ "turno 1 cobre só a mensagem 1", [ 1 ], [ 1 ], { turn: 1, seq: 1 } ],
    [ "mensagem 2 supera o turno 1 no commit", "superseded", "superseded", { turn: 1, seq: 2 } ],
    [ "resposta do turno 1 rejeitada como turno_superado", "turno_superado", "turno_superado", { turn: 1, seq: nil } ],
    [ "nenhuma saída do turno 1", 0, 0, { turn: 1, seq: nil } ],
    [ "turno 2 cobre as mensagens 1 e 2", [ 1, 2 ], [ 1, 2 ], { turn: 2, seq: 2 } ],
    [ "resposta do turno 2 aplicada", "applied", "applied", { turn: 2, seq: nil } ],
    [ "uma única saída ao cliente", 1, 1, { turn: nil, seq: 3 } ]
  ].freeze

  def race_checks(failing: nil)
    RACE_CHECKS.map do |name, expected, observed, evidence|
      observed = 2 if name == failing
      { "name" => name, "expected" => expected, "observed" => observed, "ok" => expected == observed,
        "evidence" => evidence.stringify_keys }
    end
  end

  def create_eval_run(brand:, ticket: nil, status: "passed", checks: nil, started_at: Time.current - 5.seconds, **attrs)
    checks ||= race_checks
    EvalRun.create!(
      scenario: "corrida-3s", status:, agent_model: "eval-fixture", agent_version: "corrida-3s.v1",
      config_hash: "sha256:#{'ab12' * 16}", expected: { "outbound_seqs" => [ 3 ] },
      observed: { "outbound_seqs" => [ 3 ], "rejections" => [ { "turn" => 1, "reason" => "turno_superado" } ] },
      checks:, brand_id: brand.id, ticket_id: ticket&.id, trace_id: SecureRandom.hex(16),
      started_at:, finished_at: started_at + 4.2.seconds, **attrs
    )
  end
end

RSpec.configure { |c| c.include EvalRunHelpers }
