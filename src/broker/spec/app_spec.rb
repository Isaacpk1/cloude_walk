RSpec.describe "Broker de webhooks (RF-30, RNF-23, RNF-28)" do
  let(:producer) { buffered_producer }
  let(:log) { StringIO.new }
  let(:broker) { Broker::App.build(producer:, log: Broker::Log.new(log)) }

  def app = broker
  def inbound = messages_in(producer, Broker::TOPICS.fetch(:inbound))
  def dlq = messages_in(producer, Broker::TOPICS.fetch(:dlq))
  def log_lines = log.string.lines.map { JSON.parse(_1) }

  describe "RF-30: webhook assinado e dentro do contrato" do
    it "publica o mesmo envelope em agent.inbound com a chave conversation_id e só responde depois do Kafka" do
      payload = event
      post_webhook(payload)

      expect(last_response.status).to eq(200)
      expect(json_body).to include("status" => "published", "event_id" => payload["event_id"],
                                   "topic" => "helpdesk.agent.inbound.v1", "partition" => 0, "offset" => 0)
      expect(inbound.size).to eq(1)
      expect(inbound.first[:key]).to eq(payload["conversation_id"])
      expect(inbound.first[:payload]).to eq(JSON.generate(payload))
      expect(dlq).to be_empty
    end

    it "RF-56: leva event_id e traceparent como cabeçalhos da mensagem do Kafka" do
      parent = traceparent
      payload = event
      post_webhook(payload, headers: { "HTTP_TRACEPARENT" => parent })

      expect(inbound.first[:headers]).to include("event_id" => payload["event_id"], "traceparent" => parent,
                                                 "schema" => "helpdesk.agent_event.v1")
    end

    it "RNF-13: eventos da mesma conversa usam a mesma chave e conversas diferentes, chaves diferentes" do
      post_webhook(event("conversation_id" => "tkt_1"))
      post_webhook(event("conversation_id" => "tkt_1"))
      post_webhook(event("conversation_id" => "tkt_2"))

      expect(inbound.map { _1[:key] }).to eq(%w[tkt_1 tkt_1 tkt_2])
    end

    it "invariante 13: registra a publicação em JSON com trace_id, sem o texto do cliente" do
      post_webhook

      line = log_lines.find { _1["event"] == "webhook.published" }
      expect(line).to include("trace_id" => trace_id, "conversation_id" => "tkt_01JD3K8ZQ4V6", "status" => 200)
      expect(log.string).not_to include("Meu repasse de ontem")
    end
  end

  describe "RNF-23: assinatura" do
    it "recusa sem assinatura com 401 e não publica nada, nem na DLQ" do
      post_webhook(headers: { "HTTP_X_HELPDESK_SIGNATURE" => nil })

      expect(last_response.status).to eq(401)
      expect(json_body).to include("status" => "unauthorized", "reason" => "ausente")
      expect(producer.client.messages).to be_empty
    end

    it "recusa assinatura com outro segredo" do
      post_webhook(secret: "segredo-de-outra-pessoa")

      expect(last_response.status).to eq(401)
      expect(json_body["reason"]).to eq("nao_confere")
      expect(producer.client.messages).to be_empty
    end

    it "recusa corpo alterado depois de assinado" do
      payload = event
      signature = HelpdeskContracts::Signature.header(JSON.generate(payload), secret: KafkaHelpers::SECRET)
      tampered = JSON.generate(payload.merge("brand" => "jim"))
      post_webhook(payload, body: tampered, headers: { "HTTP_X_HELPDESK_SIGNATURE" => signature })

      expect(last_response.status).to eq(401)
      expect(producer.client.messages).to be_empty
    end

    it "recusa assinatura malformada" do
      post_webhook(headers: { "HTTP_X_HELPDESK_SIGNATURE" => "sha256=abc" })

      expect(last_response.status).to eq(401)
      expect(json_body["reason"]).to eq("malformada")
    end

    it "tempo no limite: aceita a assinatura de exatamente 5 min atrás" do
      post_webhook(at: Time.now - 300)

      expect(last_response.status).to eq(200)
    end

    it "tempo no limite: recusa a assinatura de 5 min e 1 s atrás (replay)" do
      post_webhook(at: Time.now - 301)

      expect(last_response.status).to eq(401)
      expect(json_body["reason"]).to eq("fora_da_janela")
      expect(producer.client.messages).to be_empty
    end

    it "registra a recusa em JSON com o motivo e o trace_id" do
      post_webhook(secret: "outro")

      expect(log_lines.last).to include("event" => "webhook.unauthorized", "reason" => "nao_confere",
                                        "trace_id" => trace_id, "status" => 401)
    end
  end

  describe "RNF-28, invariante 10: contrato" do
    it "manda o evento fora do contrato para a DLQ, sem publicar no tópico de entrada, e responde 422" do
      payload = event.tap { _1.delete("turn") }
      post_webhook(payload)

      expect(last_response.status).to eq(422)
      expect(json_body).to include("status" => "invalid", "reason" => "contrato")
      expect(json_body["violations"]).to include(a_hash_including("pointer" => "/turn", "type" => "required"))
      expect(inbound).to be_empty
      expect(dlq.size).to eq(1)
      expect(dlq.first[:key]).to eq(payload["conversation_id"])
      expect(dlq.first[:payload]).to eq(JSON.generate(payload))
      expect(dlq.first[:headers]).to include("event_id" => payload["event_id"], "dlq_reason" => "contrato",
                                             "dlq_source" => "broker")
      expect(JSON.parse(dlq.first[:headers]["dlq_violations"])).to include(a_hash_including("pointer" => "/turn"))
    end

    it "manda JSON malformado (mas assinado) para a DLQ, com a chave do event_id do cabeçalho" do
      event_id = SecureRandom.uuid
      post_webhook(nil, body: "{nao e json", headers: { "HTTP_X_HELPDESK_EVENT_ID" => event_id })

      expect(last_response.status).to eq(422)
      expect(dlq.size).to eq(1)
      expect(dlq.first[:key]).to eq(event_id)
      expect(dlq.first[:headers]["dlq_reason"]).to eq("contrato")
    end

    it "recusa um event_id do cabeçalho diferente do corpo" do
      post_webhook(event, headers: { "HTTP_X_HELPDESK_EVENT_ID" => SecureRandom.uuid })

      expect(last_response.status).to eq(422)
      expect(json_body["reason"]).to eq("event_id_divergente")
      expect(inbound).to be_empty
      expect(dlq.size).to eq(1)
    end

    it "RF-56: recusa o evento sem traceparent válido, porque não daria para correlacionar" do
      post_webhook(event, headers: { "HTTP_TRACEPARENT" => "invalido" })

      expect(last_response.status).to eq(422)
      expect(json_body["reason"]).to eq("traceparent_invalido")
      expect(inbound).to be_empty
      expect(dlq.size).to eq(1)
    end
  end

  describe "RNF-15: repetição" do
    it "publica uma vez o mesmo event_id reentregue e confirma de novo com o mesmo resultado" do
      payload = event
      post_webhook(payload)
      first = json_body
      post_webhook(payload)

      expect(last_response.status).to eq(200)
      expect(json_body).to eq(first.merge("status" => "duplicate"))
      expect(inbound.size).to eq(1)
    end
  end

  describe "falha de dependência (07, seção 6)" do
    let(:failing) { KafkaHelpers::FailingProducer.new.delegate_to(buffered_producer) }
    let(:broker) { Broker::App.build(producer: failing, log: Broker::Log.new(log)) }

    it "responde 503 com Retry-After quando o Kafka não confirma, para a plataforma tentar de novo" do
      post_webhook

      expect(last_response.status).to eq(503)
      expect(last_response.headers["Retry-After"]).to eq("1")
      expect(json_body).to include("status" => "unavailable")
      expect(log_lines.last).to include("event" => "webhook.kafka_unavailable", "trace_id" => trace_id)
    end

    it "não guarda como publicado o que o Kafka recusou: a retentativa publica" do
      payload = event
      post_webhook(payload)
      expect(last_response.status).to eq(503)

      failing.heal!
      post_webhook(payload)
      expect(last_response.status).to eq(200)
      expect(json_body["status"]).to eq("published")
    end

    it "responde 503 quando nem a DLQ aceita o evento inválido" do
      post_webhook(event.tap { _1.delete("brand") })

      expect(last_response.status).to eq(503)
      expect(log_lines.last).to include("event" => "webhook.kafka_unavailable")
    end
  end

  describe "concorrência" do
    it "duas entregas simultâneas do mesmo event_id publicam uma vez; a outra pede nova tentativa" do
      dedup = Broker::Dedup.new
      payload = event
      body = JSON.generate(payload)
      started = Queue.new
      gate = Queue.new
      slow = Object.new
      inner = producer
      slow.define_singleton_method(:produce_sync) do |message|
        started << true
        gate.pop
        inner.produce_sync(message)
      end
      app = Broker::App.build(producer: slow, log: Broker::Log.new(log), dedup:)
      env = lambda do
        Rack::MockRequest.env_for("/webhooks", method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                                  "HTTP_X_HELPDESK_SIGNATURE" => HelpdeskContracts::Signature.header(body, secret: KafkaHelpers::SECRET),
                                  "HTTP_X_HELPDESK_EVENT_ID" => payload["event_id"], "HTTP_TRACEPARENT" => traceparent)
      end

      first = Thread.new { app.call(env.call) }
      started.pop
      second = app.call(env.call)
      gate << true

      expect(first.value.first).to eq(200)
      expect(second.first).to eq(503)
      expect(inbound.size).to eq(1)
    end
  end

  it "responde /up para o healthcheck do Compose" do
    get "/up"

    expect(last_response.status).to eq(200)
  end
end
