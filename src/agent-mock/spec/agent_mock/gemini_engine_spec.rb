RSpec.describe AgentMock::Scenarios::GeminiEngine do
  # Cliente falso: guarda as chamadas e devolve o que o teste mandar. Sem rede.
  class FakeGemini
    attr_reader :calls

    def initialize(reply: nil, error: nil)
      @reply = reply
      @error = error
      @calls = []
    end

    def generate(**args)
      @calls << args
      raise @error if @error

      @reply || JSON.generate("text" => "Seu repasse está em processamento.")
    end
  end

  let(:config) { AgentMock::Config.load(env: { "AGENT_ENGINE" => "gemini" }) }
  let(:io) { StringIO.new }
  let(:log) { AgentMock::Log.new(io) }
  let(:budget) { described_class::Budget.new(max_calls: 100, max_concurrency: 2) }

  def engine(client, budget: self.budget) = described_class.new(config, client:, budget:, log:)

  describe "ADR-030: a política fica nas regras" do
    [ "quero falar com um atendente", "preciso de um estorno do pix", "quero trocar a conta bancária", "obrigado, resolvido" ].each do |text|
      it "#{text.inspect} é decidido pelas regras, sem chamar o modelo" do
        client = FakeGemini.new

        decision = engine(client).decide(inbound(texts: [ text ]))

        expect(client.calls).to be_empty
        expect(decision.rule).not_to end_with(".gemini")
        expect(%w[escalate resolve]).to include(decision.action)
      end
    end

    it "limite de trocas escala sem chamar o modelo (RN-33)" do
      client = FakeGemini.new

      decision = engine(client).decide(inbound(texts: [ "meu repasse não caiu" ], ai_turns: 10))

      expect(client.calls).to be_empty
      expect(decision).to have_attributes(action: "escalate", rule: "limite_de_trocas")
    end

    it "cliente não verificado recebe o pedido de identificação das regras (RN-05)" do
      client = FakeGemini.new

      decision = engine(client).decide(inbound(texts: [ "meu repasse não caiu" ], verified: false))

      expect(client.calls).to be_empty
      expect(decision.rule).to end_with(".verificacao_pendente")
    end
  end

  describe "o modelo redige a resposta" do
    it "usa o texto do modelo e mantém as consultas sintéticas da decisão" do
      client = FakeGemini.new(reply: JSON.generate("text" => "Seu repasse está pendente."))

      decision = engine(client).decide(inbound(texts: [ "meu repasse não caiu" ]))

      expect(client.calls.size).to eq(1)
      expect(decision).to have_attributes(action: "reply", content: { "reply" => { "text" => "Seu repasse está pendente." } })
      expect(decision.rule).to end_with(".gemini")
      expect(decision.tool_calls.map { _1["tool"] }).to include("get_settlement_status")
    end

    it "manda ao modelo os dados consultados, o texto do cliente e o modelo e a temperatura da configuração" do
      client = FakeGemini.new
      event = inbound(texts: [ "meu repasse não caiu" ])

      engine(client).decide(event)

      args = client.calls.first
      prompt = JSON.parse(args[:prompt])
      expect(args).to include(model: config.llm["model"], temperature: config.llm["temperature"])
      expect(prompt["mensagens_do_cliente"]).to eq([ "meu repasse não caiu" ])
      expect(prompt["dados_consultados"].first).to include("ferramenta" => "get_settlement_status")
      expect(prompt["cliente_verificado"]).to be(true)
    end

    it "não manda identificador, nome nem contato do cliente ao modelo (RN-51)" do
      client = FakeGemini.new
      event = inbound(texts: [ "meu repasse não caiu" ])

      engine(client).decide(event)

      sent = client.calls.first[:prompt]
      expect(sent).not_to include(event.dig("customer", "id"))
      [ "display_name", "phone", "email" ].each { |field| expect(sent).not_to include(event.dig("customer", field).to_s) if event.dig("customer", field) }
    end
  end

  describe "degradação: nunca fica sem resposta" do
    it "erro do provedor devolve a resposta das regras e registra agent.llm_fallback" do
      client = FakeGemini.new(error: AgentMock::GeminiClient::Error.new("gemini_http_429"))
      base = AgentMock::Scenarios::Engine.new(config).decide(inbound(texts: [ "meu repasse não caiu" ]))

      decision = engine(client).decide(inbound(texts: [ "meu repasse não caiu" ]))

      expect(decision.content).to eq(base.content)
      expect(io.string).to include("agent.llm_fallback", "gemini_http_429")
    end

    [ "{}", "não é json", JSON.generate("text" => "   "), JSON.generate("text" => 42) ].each do |raw|
      it "saída inválida (#{raw.inspect}) cai nas regras" do
        decision = engine(FakeGemini.new(reply: raw)).decide(inbound(texts: [ "meu repasse não caiu" ]))

        expect(decision.rule).not_to end_with(".gemini")
        expect(io.string).to include("agent.llm_fallback")
      end
    end

    it "teto de chamadas atingido cai nas regras, sem chamar o modelo (custo)" do
      client = FakeGemini.new
      limited = engine(client, budget: described_class::Budget.new(max_calls: 1, max_concurrency: 1))

      first = limited.decide(inbound(texts: [ "meu repasse não caiu" ]))
      second = limited.decide(inbound(texts: [ "meu repasse não caiu" ]))

      expect(client.calls.size).to eq(1)
      expect(first.rule).to end_with(".gemini")
      expect(second.rule).not_to end_with(".gemini")
      expect(io.string).to include("teto_de_chamadas")
    end

    it "devolve a vaga de simultaneidade mesmo quando o modelo falha" do
      failing = engine(FakeGemini.new(error: AgentMock::GeminiClient::Error.new("gemini_http_500")),
                       budget: described_class::Budget.new(max_calls: 10, max_concurrency: 1))

      3.times { failing.decide(inbound(texts: [ "meu repasse não caiu" ])) }

      expect(io.string.scan("agent.llm_fallback").size).to eq(3)
    end
  end

  describe "RN-37: configuração registrada" do
    it "o hash do motor Gemini difere do das regras e muda com o modelo" do
      rules = AgentMock::Config.load(env: {})
      other = AgentMock::Config.load(env: { "AGENT_ENGINE" => "gemini", "GEMINI_MODEL" => "outro-modelo" })

      expect([ rules.config_hash, config.config_hash, other.config_hash ].uniq.size).to eq(3)
      expect(config.agent_model).to eq(config.llm["model"])
      expect(rules.agent_model).to eq(AgentMock::MODEL)
    end

    it "a chave da API nunca entra na configuração efetiva" do
      with_key = AgentMock::Config.load(env: { "AGENT_ENGINE" => "gemini", "GEMINI_API_KEY" => "chave-sintetica-123" })

      expect(JSON.generate(with_key.effective)).not_to include("chave-sintetica-123")
      expect(with_key.config_hash).to eq(config.config_hash)
    end

    it "motor desconhecido derruba a subida" do
      expect { AgentMock::Config.load(env: { "AGENT_ENGINE" => "gpt" }) }.to raise_error(AgentMock::Config::Invalid, /AGENT_ENGINE/)
    end

    it "sem GEMINI_API_KEY o cliente real derruba a subida" do
      expect { AgentMock::GeminiClient.new(api_key: "") }.to raise_error(AgentMock::Config::Invalid, /GEMINI_API_KEY/)
    end
  end
end
