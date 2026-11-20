RSpec.describe AgentMock::Scenarios::Engine do
  let(:raw) { YAML.safe_load_file(AgentMock::Config::DEFAULT_PATH) }

  def engine_with(rules) = described_class.new(AgentMock::Config.new(raw.merge("rules" => rules), env: {}))

  describe "ADR-008, RF-38: regras configuráveis" do
    it "regra do tipo reply responde com o texto fixo da regra" do
      engine = engine_with([ { "id" => "horario", "type" => "reply", "any" => [ "horario" ], "text" => "Atendemos 24 h." } ])

      decision = engine.decide(inbound(texts: [ "Qual o horário de atendimento?" ]))

      expect(decision).to have_attributes(action: "reply", rule: "horario", content: { "reply" => { "text" => "Atendemos 24 h." } })
    end

    it "vale a primeira regra que casar, na ordem do arquivo" do
      decision = described_class.new(AgentMock::Config.load(env: {}))
                                .decide(inbound(texts: [ "O repasse não caiu", "quero um humano" ]))

      expect(decision).to have_attributes(action: "escalate", rule: "pedido_de_humano")
    end

    it "tipo de regra desconhecido falha na subida (RN-35: nada fora do catálogo)" do
      expect { engine_with([ { "id" => "x", "type" => "refund", "any" => [ "estorno" ] } ]) }
        .to raise_error(AgentMock::Config::Invalid, /refund/)
    end

    it "consulta fora do catálogo falha na subida (RN-35)" do
      expect { engine_with([ { "id" => "x", "type" => "tool_reply", "tool" => "refund_transaction", "any" => [ "estorno" ] } ]) }
        .to raise_error(AgentMock::Config::Invalid, /refund_transaction/)
    end
  end
end
