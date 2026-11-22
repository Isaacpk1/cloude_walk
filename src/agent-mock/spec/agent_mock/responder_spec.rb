RSpec.describe AgentMock::Responder do
  let(:producer) { buffered_producer }
  let(:clock) { KafkaHelpers::FakeClock.new }
  let(:io) { StringIO.new }
  let(:env) { { "AGENT_LATENCY_MS" => "0" } }
  let(:config) { AgentMock::Config.load(env:) }
  subject(:responder) { described_class.new(producer:, config:, log: AgentMock::Log.new(io), clock:) }

  def deliver(event, headers: headers_for(event), payload: JSON.generate(event))
    responder.call(payload:, headers:)
  end

  def expect_valid_action(action) = expect(HelpdeskContracts.errors(:agent_outbound, action).map(&:to_s)).to eq([])

  describe "RF-32, RF-33: pedido de repasse vira consulta + reply" do
    it "consulta get_settlement_status e responde com o resultado, no contrato agent_outbound" do
      event = inbound(texts: [ "Meu repasse de ontem não caiu" ])

      result = deliver(event)

      expect(result.status).to eq(:published)
      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("reply")
      expect(action["tool_calls"].map { _1["tool"] }).to eq([ "get_settlement_status" ])
      call = action["tool_calls"].first
      expect(call.keys).to contain_exactly("tool", "args", "result", "duration_ms")
      expect(call["args"]).to include("date" => "2026-11-16")
      expect(action.dig("reply", "text")).to include(call.dig("result", "status").tr("_", " "))
      expect(action["classification"]).to eq("category" => "repasses")
    end

    it "lê todas as pending_messages, não só a última" do
      deliver(inbound(texts: [ "O repasse de ontem", "ainda nada até agora" ]))

      expect(action_in(producer)["tool_calls"].map { _1["tool"] }).to eq([ "get_settlement_status" ])
    end
  end

  describe "RF-32: consultas de transação e de taxa" do
    it "status de transação vira get_transaction_status + reply" do
      deliver(inbound(texts: [ "Minha venda de ontem foi aprovada?" ]))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["tool_calls"].map { _1["tool"] }).to eq([ "get_transaction_status" ])
      expect(action.dig("reply", "text")).to include(action["tool_calls"].first.dig("result", "reference"))
    end

    it "taxa vira get_fee com o meio de pagamento do texto" do
      deliver(inbound(texts: [ "Qual a taxa do pix?" ]))

      call = action_in(producer)["tool_calls"].first
      expect(call).to include("tool" => "get_fee", "args" => { "brand" => "infinitepay", "method" => "pix" })
      expect(action_in(producer).dig("reply", "text")).to include("pix")
    end
  end

  describe "RN-34, RN-39: cliente pede humano" do
    it "escala com reason e o resumo com os cinco campos, sem PII" do
      event = inbound(texts: [ "Meu repasse não caiu", "quero falar com um atendente" ])

      deliver(event)

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("escalate")
      expect(action.dig("escalation", "reason")).to eq("cliente_pediu_humano")
      expect(action.dig("escalation", "summary").keys)
        .to contain_exactly("problema", "dados_cliente", "acoes_tomadas", "motivo", "pendente")
      expect(action.dig("escalation", "summary", "dados_cliente")).not_to include(event.dig("customer", "display_name"))
      expect(action).not_to have_key("reply")
    end

    it "palavra inteira: 'pessoal' não é pedido de humano" do
      deliver(inbound(texts: [ "Tenho uma dúvida pessoal" ]))

      expect(action_in(producer)["action"]).to eq("reply")
    end
  end

  describe "RN-35: dinheiro e cadastro são de humanos" do
    it "pedido de estorno é escalado, nunca executado" do
      deliver(inbound(texts: [ "Quero um estorno da venda de ontem" ]))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("escalate")
      expect(action.dig("escalation", "reason")).to eq("acao_exclusiva_humana")
      expect(action.fetch("tool_calls", [])).to be_empty
    end
  end

  describe "RN-36: resolve só com confirmação do cliente" do
    it "'obrigado, resolvido' vira resolve com resolution.reason" do
      deliver(inbound(texts: [ "Obrigado, resolvido!" ]))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("resolve")
      expect(action.dig("resolution", "reason")).to eq("confirmado_pelo_cliente")
    end

    it "'não resolveu' não encerra" do
      deliver(inbound(texts: [ "Não resolveu, obrigado" ]))

      expect(action_in(producer)["action"]).to eq("reply")
    end

    [ "ainda não está resolvido", "não foi resolvido", "resolveu?", "nada foi resolvido", "não resolveu ainda" ].each do |text|
      it "#{text.inspect} não encerra: publica reply, não resolve" do
        deliver(inbound(texts: [ text ]))

        action = action_in(producer)
        expect_valid_action(action)
        expect(action["action"]).to eq("reply")
      end
    end

    [ "deu certo, obrigado", "resolveu sim" ].each do |text|
      it "#{text.inspect} encerra com resolve" do
        deliver(inbound(texts: [ text ]))

        expect(action_in(producer)).to include("action" => "resolve", "resolution" => include("reason" => "confirmado_pelo_cliente"))
      end
    end

    it "'obrigado' sozinho não é confirmação" do
      deliver(inbound(texts: [ "Obrigado" ]))

      expect(action_in(producer)["action"]).to eq("reply")
    end
  end

  describe "RF-32: sem regra que case, reply padrão" do
    it "responde com o texto padrão, sem consulta" do
      deliver(inbound(texts: [ "Bom dia" ]))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action).to include("action" => "reply", "tool_calls" => [])
      expect(action.dig("reply", "text")).to eq(config.replies.fetch("default"))
    end
  end

  describe "RN-05: cliente não verificado" do
    it "não consulta dados de conta e pede identificação" do
      deliver(inbound(texts: [ "Meu repasse não caiu" ], verified: false))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("reply")
      expect(action["tool_calls"]).to eq([])
      expect(action.dig("reply", "text")).to eq(config.replies.fetch("needs_verification"))
    end

    it "consulta que não é dado de conta (taxa) segue liberada" do
      deliver(inbound(texts: [ "Qual a taxa no débito?" ], verified: false))

      expect(action_in(producer)["tool_calls"].map { _1["tool"] }).to eq([ "get_fee" ])
    end
  end

  describe "RN-33: limite de 10 trocas da IA" do
    it "com ai_turns = 10 escala, mesmo com regra de consulta casando" do
      deliver(inbound(texts: [ "Meu repasse não caiu" ], ai_turns: 10))

      action = action_in(producer)
      expect_valid_action(action)
      expect(action["action"]).to eq("escalate")
      expect(action.dig("escalation", "reason")).to eq("limite_de_trocas")
      expect(action["tool_calls"]).to eq([])
    end

    it "com ai_turns = 9 ainda responde" do
      deliver(inbound(texts: [ "Meu repasse não caiu" ], ai_turns: 9))

      expect(action_in(producer)["action"]).to eq("reply")
    end
  end

  describe "07, seção 5.3; RN-37: correlação, agent e timing" do
    it "devolve a correlação do evento, agent com modelo, versão e config_hash, e timing" do
      event = inbound(texts: [ "Bom dia" ])
      clock.advance(0) # recebe em T0

      deliver(event)

      action = action_in(producer)
      expect(action).to include(
        "schema" => "helpdesk.agent_action.v1", "in_reply_to" => event["event_id"],
        "conversation_id" => event["conversation_id"], "brand" => event["brand"], "turn" => event["turn"],
        "context_until_seq" => event["context_until_seq"], "assignment_version" => event["assignment_version"]
      )
      expect(action["event_id"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(action["event_id"]).not_to eq(event["event_id"])
      expect(action["agent"]).to eq("model" => "mock-deterministico", "version" => AgentMock::VERSION,
                                    "config_hash" => config.config_hash)
      expect(action["agent"]["config_hash"]).to match(/\Asha256:\h{64}\z/)
      expect(action["timing"]).to eq("received_at" => "2026-11-17T13:40:01.760Z",
                                     "responded_at" => "2026-11-17T13:40:01.760Z", "agent_ms" => 0)
    end
  end

  describe "RF-30, RF-56: chave e cabeçalhos da publicação" do
    it "publica em outbound com chave conversation_id e cabeçalhos event_id da ação, traceparent recebido e schema" do
      event = inbound(texts: [ "Bom dia" ])

      deliver(event)

      message = sole(outbound(producer))
      action = JSON.parse(message[:payload])
      expect(message[:key]).to eq(event["conversation_id"])
      expect(message[:headers]).to eq("event_id" => action["event_id"], "traceparent" => traceparent,
                                      "schema" => "helpdesk.agent_action.v1")
      expect(dlq(producer)).to be_empty
    end

    it "sem traceparent no evento, publica sem o cabeçalho (a plataforma usa o trace do turno)" do
      event = inbound(texts: [ "Bom dia" ])

      deliver(event, headers: headers_for(event).except("traceparent"))

      expect(sole(outbound(producer))[:headers].keys).to contain_exactly("event_id", "schema")
    end
  end

  describe "RNF-30: determinismo" do
    it "mesma entrada, mesma configuração e mesma semente dão a mesma ação (exceto event_id e timing)" do
      event = inbound(texts: [ "Meu repasse não caiu", "e a taxa do crédito?" ])
      other = described_class.new(producer:, config: AgentMock::Config.load(env:), log: AgentMock::Log.new(StringIO.new),
                                  clock: KafkaHelpers::FakeClock.new)

      deliver(event)
      other.call(payload: JSON.generate(event), headers: headers_for(event))

      first, second = outbound(producer).map { JSON.parse(_1[:payload]).except("event_id", "timing") }
      expect(second).to eq(first)
    end

    it "outra semente muda o resultado da consulta e o config_hash" do
      event = inbound(texts: [ "Meu repasse não caiu" ])
      seeded = described_class.new(producer:, config: AgentMock::Config.load(env: env.merge("AGENT_SEED" => "7")),
                                   log: AgentMock::Log.new(StringIO.new), clock:)

      deliver(event)
      seeded.call(payload: JSON.generate(event), headers: headers_for(event))

      first, second = outbound(producer).map { JSON.parse(_1[:payload]) }
      expect(second.dig("tool_calls", 0, "result")).not_to eq(first.dig("tool_calls", 0, "result"))
      expect(second.dig("agent", "config_hash")).not_to eq(first.dig("agent", "config_hash"))
    end
  end

  describe "RN-47: evento repetido (mesmo event_id)" do
    it "responde de novo com outro event_id de ação: a idempotência é da plataforma" do
      event = inbound(texts: [ "Meu repasse não caiu" ])

      2.times { deliver(event) }

      actions = outbound(producer).map { JSON.parse(_1[:payload]) }
      expect(actions.map { _1["in_reply_to"] }).to eq([ event["event_id"] ] * 2)
      expect(actions.map { _1["event_id"] }.uniq.size).to eq(2)
      expect(actions.map { _1.except("event_id", "timing") }.uniq.size).to eq(1)
    end
  end

  describe "RN-46; 07, seção 6: evento vencido é descartado" do
    let(:event) { inbound(texts: [ "Meu repasse não caiu" ]) }

    it "um instante antes do prazo, responde" do
      clock.advance(19.999)

      expect(deliver(event).status).to eq(:published)
    end

    it "no limite exato do deadline_at, descarta" do
      clock.advance(20)

      expect(deliver(event).status).to eq(:expired)
      expect(producer.client.messages).to be_empty
    end

    it "um instante depois do prazo, descarta e loga sem PII" do
      clock.advance(20.001)

      expect(deliver(event).status).to eq(:expired)
      expect(producer.client.messages).to be_empty
      line = sole(log_lines(io))
      expect(line).to include("event" => "agent.expired", "reason" => "prazo_vencido", "trace_id" => trace_id,
                              "event_id" => event["event_id"])
    end
  end

  describe "invariante 10, RN-44: evento fora do contrato agent_inbound" do
    it "vai para a DLQ com o corpo original e os cabeçalhos, sem resposta" do
      event = inbound.except("turn")
      body = JSON.generate(event)

      result = deliver(event, payload: body)

      expect(result.status).to eq(:dead_lettered)
      expect(outbound(producer)).to be_empty
      message = sole(dlq(producer))
      expect(message[:payload]).to eq(body)
      expect(message[:key]).to eq(event["conversation_id"])
      expect(message[:headers]).to include("dlq_reason" => "contrato", "dlq_source" => "agent-mock",
                                           "event_id" => event["event_id"], "traceparent" => traceparent)
      expect(JSON.parse(message[:headers]["dlq_violations"]).map { _1["pointer"] }).to include("/turn")
    end

    it "JSON malformado também vai para a DLQ, com a chave do event_id do cabeçalho" do
      event_id = SecureRandom.uuid

      result = responder.call(payload: "{nao e json", headers: { "event_id" => event_id, "traceparent" => traceparent })

      expect(result.status).to eq(:dead_lettered)
      expect(sole(dlq(producer))).to include(key: event_id, payload: "{nao e json")
    end
  end

  describe "RN-35, invariante 10: ação gerada fora do contrato agent_outbound" do
    it "não publica em outbound e manda para a DLQ como acao_invalida" do
      broken = AgentMock::Config.load(env:)
      allow(broken).to receive(:replies).and_return(broken.replies.merge("default" => "   "))
      responder = described_class.new(producer:, config: broken, log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Bom dia" ])

      result = responder.call(payload: JSON.generate(event), headers: headers_for(event))

      expect(result.status).to eq(:dead_lettered)
      expect(outbound(producer)).to be_empty
      message = sole(dlq(producer))
      expect(message[:headers]).to include("dlq_reason" => "acao_invalida", "dlq_source" => "agent-mock")
      expect(JSON.parse(message[:payload])).to include("in_reply_to" => event["event_id"], "action" => "reply")
      expect(log_lines(io).map { _1["event"] }).to include("agent.invalid_action")
    end
  end

  describe "07, seção 6: Kafka não confirma a publicação" do
    it "propaga o erro (o Karafka não confirma o offset e o evento volta)" do
      failing = KafkaHelpers::FailingProducer.new
      responder = described_class.new(producer: failing, config:, log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Bom dia" ])

      expect { responder.call(payload: JSON.generate(event), headers: headers_for(event)) }
        .to raise_error(WaterDrop::Errors::ProduceError)
      expect(failing.attempts.map { _1[:topic] }).to eq([ "helpdesk.agent.outbound.v1" ])
    end

    it "também propaga quando a DLQ não confirma" do
      failing = KafkaHelpers::FailingProducer.new
      responder = described_class.new(producer: failing, config:, log: AgentMock::Log.new(io), clock:)

      expect { responder.call(payload: "{}", headers: {}) }.to raise_error(WaterDrop::Errors::ProduceError)
    end
  end

  describe "RF-38: modos de falha" do
    it "modo mudo consome e não publica nada" do
      responder = described_class.new(producer:, config: AgentMock::Config.load(env: { "AGENT_PROFILE" => "mudo" }),
                                      log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Meu repasse não caiu" ])

      expect(responder.call(payload: JSON.generate(event), headers: headers_for(event)).status).to eq(:muted)
      expect(producer.client.messages).to be_empty
      expect(sole(log_lines(io))).to include("event" => "agent.muted", "trace_id" => trace_id)
    end

    it "latência injetada pelo relógio entra em timing.agent_ms, sem sleep real" do
      responder = described_class.new(producer:, config: AgentMock::Config.load(env: { "AGENT_LATENCY_MS" => "2000" }),
                                      log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Bom dia" ])

      responder.call(payload: JSON.generate(event), headers: headers_for(event))

      expect(clock.slept).to eq([ 2.0 ])
      expect(action_in(producer)["timing"]).to include("agent_ms" => 2000, "responded_at" => "2026-11-17T13:40:03.760Z")
    end

    it "agent_ms cobre a execução simulada inteira: latência + duration_ms das consultas, coerente com o relógio" do
      responder = described_class.new(producer:, config: AgentMock::Config.load(env: { "AGENT_LATENCY_MS" => "2000" }),
                                      log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Meu repasse de ontem não caiu" ])

      responder.call(payload: JSON.generate(event), headers: headers_for(event))

      action = action_in(producer)
      tools_ms = action["tool_calls"].sum { _1["duration_ms"] }
      expect(tools_ms).to be_positive
      timing = action["timing"]
      elapsed_ms = ((Time.iso8601(timing["responded_at"]) - Time.iso8601(timing["received_at"])) * 1000).round
      expect(timing["agent_ms"]).to eq(2000 + tools_ms)
      expect(elapsed_ms).to eq(timing["agent_ms"])
      expect(clock.slept).to eq([ 2.0, tools_ms / 1000.0 ])
      expect(action["tool_calls"].map { _1["duration_ms"] }).to all(be <= timing["agent_ms"])
    end

    it "agent_ms é determinístico: a mesma entrada dá o mesmo agent_ms (RNF-30)" do
      event = inbound(texts: [ "Meu repasse de ontem não caiu" ])
      2.times do
        described_class.new(producer:, config:, log: AgentMock::Log.new(io), clock: KafkaHelpers::FakeClock.new)
                       .call(payload: JSON.generate(event), headers: headers_for(event))
      end

      expect(outbound(producer).map { JSON.parse(_1[:payload])["timing"] }.uniq.size).to eq(1)
    end

    it "latência que passa do prazo ainda publica: quem rejeita a resposta tardia é a plataforma (RN-46)" do
      responder = described_class.new(producer:, config: AgentMock::Config.load(env: { "AGENT_LATENCY_MS" => "25000" }),
                                      log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Bom dia" ])

      expect(responder.call(payload: JSON.generate(event), headers: headers_for(event)).status).to eq(:published)
    end

    it "taxa de falha com semente: a ação não sai e o resultado se repete na mesma semente" do
      failing_env = { "AGENT_LATENCY_MS" => "0", "AGENT_FAILURE_RATE" => "0.5" }
      events = Array.new(40) { inbound(texts: [ "Bom dia" ]) }
      run = lambda do
        buffer = buffered_producer
        responder = described_class.new(producer: buffer, config: AgentMock::Config.load(env: failing_env),
                                        log: AgentMock::Log.new(StringIO.new), clock:)
        events.map { responder.call(payload: JSON.generate(_1), headers: headers_for(_1)).status }
      end

      first = run.call
      expect(first).to include(:failed, :published)
      expect(run.call).to eq(first)
    end

    it "taxa de falha 1.0 nunca publica" do
      responder = described_class.new(producer:, config: AgentMock::Config.load(env: { "AGENT_FAILURE_RATE" => "1" }),
                                      log: AgentMock::Log.new(io), clock:)
      event = inbound(texts: [ "Bom dia" ])

      expect(responder.call(payload: JSON.generate(event), headers: headers_for(event)).status).to eq(:failed)
      expect(producer.client.messages).to be_empty
    end
  end

  describe "RF-38: perfil escolhido pelo simulador" do
    let(:redis) { KafkaHelpers::FakeControlRedis.new }
    let(:profiles) do
      AgentMock::Profiles.new(config: AgentMock::Config.load(env: {}), source: AgentMock::ProfileSource.new(redis:),
                              log: AgentMock::Log.new(io))
    end
    let(:live) { described_class.new(producer:, profiles:, log: AgentMock::Log.new(io), clock:) }
    let(:key) { AgentMock::ProfileSource.key("brand:infinitepay") }

    def send_event(responder = live, texts: [ "Bom dia" ])
      event = inbound(texts:)
      responder.call(payload: JSON.generate(event), headers: headers_for(event))
    end

    it "usa o perfil gravado no evento seguinte, sem reiniciar o agente" do
      expect(send_event.status).to eq(:published)

      redis.set(key, "mudo")
      expect(send_event.status).to eq(:muted)
      expect(log_lines(io).last).to include("event" => "agent.muted", "profile" => "mudo", "profile_source" => "brand")

      redis.del(key)
      expect(send_event.status).to eq(:published)
      expect(outbound(producer).size).to eq(2)
    end

    it "mudo não publica nada, nem na DLQ" do
      redis.set(AgentMock::ProfileSource.key("global"), "mudo")

      3.times { send_event }

      expect(producer.client.messages).to be_empty
    end

    it "lento responde depois do aviso de progresso (15 s) e antes do prazo do turno (20 s), com semente" do
      redis.set(key, "lento")
      latencies = Array.new(30) do
        clock = KafkaHelpers::FakeClock.new
        responder = described_class.new(producer:, profiles:, log: AgentMock::Log.new(StringIO.new), clock:)
        send_event(responder).action.dig("timing", "agent_ms")
      end

      expect(latencies).to all(be > 15_000).and(all(be < 20_000))
      expect(latencies.uniq.size).to be > 1
    end

    it "lento é determinístico: o mesmo evento dá a mesma latência (RNF-30)" do
      redis.set(key, "lento")
      event = inbound(texts: [ "Bom dia" ])
      timings = Array.new(2) do
        described_class.new(producer:, profiles:, log: AgentMock::Log.new(StringIO.new), clock: KafkaHelpers::FakeClock.new)
                       .call(payload: JSON.generate(event), headers: headers_for(event)).action["timing"]
      end

      expect(timings.uniq.size).to eq(1)
    end

    it "o config_hash da ação reflete o perfil efetivo (RN-37)" do
      rapido = send_event.action.dig("agent", "config_hash")
      redis.set(key, "lento")
      lento = send_event.action

      expect(lento.dig("agent", "config_hash")).not_to eq(rapido)
      expect(lento.dig("agent", "config_hash")).to eq(AgentMock::Config.load(env: { "AGENT_PROFILE" => "lento" }).config_hash)
      expect(log_lines(io).last).to include("event" => "agent.published", "profile" => "lento",
                                            "config_hash" => lento.dig("agent", "config_hash"))
    end

    it "marca errada: o perfil de uma marca não vale para a outra" do
      redis.set(AgentMock::ProfileSource.key("brand:jim"), "mudo")

      expect(send_event.status).to eq(:published)
    end

    it "Redis fora: responde no perfil padrão e loga, sem derrubar o consumo" do
      redis.down!

      result = send_event

      expect(result.status).to eq(:published)
      expect(result.action.dig("agent", "config_hash")).to eq(AgentMock::Config.load(env: {}).config_hash)
      expect(log_lines(io).map { _1["event"] }).to eq(%w[agent.profile_source_failed agent.published])
    end
  end

  describe "RN-51, invariante 13: logs em JSON com trace_id e sem PII" do
    it "loga trace_id, event_id, conversation_id, decisão e duração, sem texto nem display_name" do
      event = inbound(texts: [ "Meu repasse não caiu, sou a Loja Exemplo" ])

      deliver(event)

      line = sole(log_lines(io))
      expect(line).to include("service" => "agent-mock", "event" => "agent.published", "trace_id" => trace_id,
                              "event_id" => event["event_id"], "conversation_id" => event["conversation_id"],
                              "action" => "reply", "rule" => "repasse",
                              "agent_ms" => action_in(producer)["tool_calls"].sum { _1["duration_ms"] })
      expect(io.string).not_to include("repasse não caiu")
      expect(io.string).not_to include(event.dig("customer", "display_name"))
    end
  end
end
