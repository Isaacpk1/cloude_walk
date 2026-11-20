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

  describe "RN-36: resolve só com confirmação afirmativa do cliente" do
    let(:engine) { described_class.new(AgentMock::Config.load(env: {})) }

    nao_confirmam = [
      "ainda não está resolvido", "não foi resolvido", "resolveu?", "nada foi resolvido", "não resolveu ainda",
      "Não resolveu, obrigado", "isso nao funcionou", "nunca deu certo", "nem funcionou", "Já resolveu? Obrigado",
      "Não foi totalmente resolvido"
    ]
    confirmam = [
      "obrigado, resolvido", "Obrigado, resolvido!", "deu certo, obrigado", "resolveu sim", "já resolvido, obrigado",
      "funcionou!", "Resolveu? Sim, resolveu."
    ]

    nao_confirmam.each do |text|
      it "#{text.inspect} não encerra o atendimento" do
        expect(engine.decide(inbound(texts: [ text ])).action).not_to eq("resolve")
      end
    end

    confirmam.each do |text|
      it "#{text.inspect} encerra com resolve" do
        expect(engine.decide(inbound(texts: [ text ]))).to have_attributes(action: "resolve", rule: "confirmacao_de_resolucao")
      end
    end

    it "pergunta numa mensagem e confirmação noutra: vale a confirmação" do
      expect(engine.decide(inbound(texts: [ "resolveu?", "sim, resolvido" ])).action).to eq("resolve")
    end

    it "negação no fim de uma mensagem não alcança o termo da mensagem seguinte além da janela" do
      decision = engine.decide(inbound(texts: [ "não sei o que houve com o pagamento de ontem", "agora deu certo, obrigado" ]))

      expect(decision.action).to eq("resolve")
    end
  end

  describe "RN-36, ADR-008: negation_window e ignore_questions são genéricos e validados na subida" do
    let(:base) do
      { "id" => "ok", "type" => "reply", "any" => [ "ok" ], "text" => "certo", "negations" => [ "nao" ], "negation_window" => 2 }
    end

    it "termo com negação até N palavras antes não casa; além da janela casa" do
      engine = engine_with([ base ])

      expect(engine.decide(inbound(texts: [ "nao esta ok" ])).rule).to eq("padrao")
      expect(engine.decide(inbound(texts: [ "nao, tudo bem agora ok" ])).rule).to eq("ok")
    end

    it "ignore_questions desconsidera o termo dentro de uma pergunta" do
      engine = engine_with([ base.merge("ignore_questions" => true) ])

      expect(engine.decide(inbound(texts: [ "ficou ok?" ])).rule).to eq("padrao")
      expect(engine.decide(inbound(texts: [ "ficou ok" ])).rule).to eq("ok")
    end

    it "configuração inválida derruba a subida (Config, não só o Engine)" do
      invalid = [ base.merge("negation_window" => 0), base.merge("negation_window" => "3"), base.except("negations"),
                  base.merge("negations" => []), base.except("negation_window"), base.merge("ignore_questions" => "sim") ]

      invalid.each do |rule|
        expect { AgentMock::Config.new(raw.merge("rules" => [ rule ]), env: {}) }
          .to raise_error(AgentMock::Config::Invalid, /regra ok/), rule.inspect
      end
    end

    it "mudar a janela ou ignore_questions muda o config_hash (RN-37)" do
      hash = ->(rule) { AgentMock::Config.new(raw.merge("rules" => [ rule ]), env: {}).config_hash }

      expect([ hash.(base), hash.(base.merge("negation_window" => 3)), hash.(base.merge("ignore_questions" => true)) ].uniq.size)
        .to eq(3)
    end
  end
end
