require "rails_helper"

RSpec.describe Outbox::Publish, "RF-30, RNF-23: publicação do evento do outbox no broker" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:jitter) { -> { 0.0 } }

  around { |example| travel_to(start) { example.run } }

  def open_event(text = "meu repasse não caiu", **)
    received = ingest(text, trace_id:, **)
    OutboxEvent.find(open_turn_for(received).event_id)
  end

  def publish(item) = described_class.call(item.id, jitter:)
  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  describe "caminho feliz" do
    it "envia o envelope assinado, com event_id e traceparent, e só encerra o item com a confirmação" do
      item = open_event
      stub_broker

      result = publish(item)

      request = broker_requests.sole
      expect { verify_broker_request!(request) }.not_to raise_error
      expect(request.body).to eq(JSON.generate(item.payload))
      expect(request.headers["X-Helpdesk-Event-Id"]).to eq(item.id)
      expect(request.headers["Traceparent"]).to match(/\A00-#{trace_id}-\h{16}-01\z/)
      expect(result.status).to eq(:published)
      expect(item.reload).to have_attributes(published_at: start, completed_at: start, attempts: 1, lease_until: nil,
                                             last_error: nil)
    end

    it "RF-54, RF-56: audita a publicação com tópico, partição, offset e o trace_id da mensagem" do
      item = open_event
      stub_broker

      publish(item)

      expect(audits("agent_event.published").sole).to have_attributes(trace_id:, brand_id: infinitepay.id,
                                                                     ticket_id: item.ticket_id, actor_type: "system")
      expect(audits("agent_event.published").sole.data).to include(
        "event_id" => item.id, "turn" => 1, "attempt" => 1, "topic" => "helpdesk.agent.inbound.v1",
        "partition" => 7, "offset" => 42, "broker_status" => "published"
      )
    end

    it "invariante 13: registra a publicação no log em JSON com trace_id" do
      item = open_event
      stub_broker
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, msg| lines << msg; m.call(msg) }

      publish(item)

      expect(lines.filter_map { JSON.parse(_1) rescue nil }).to include(
        a_hash_including("event" => "outbox.published", "trace_id" => trace_id, "event_id" => item.id)
      )
    end
  end

  describe "repetição" do
    it "RNF-15: item já publicado não é enviado de novo" do
      item = open_event
      stub_broker
      publish(item)

      expect(publish(item).status).to eq(:skipped)
      expect(broker_requests.size).to eq(1)
    end

    it "aceita o 'duplicate' do broker como publicação confirmada" do
      item = open_event
      stub_broker({ status: 200, body: JSON.generate(status: "duplicate", topic: "helpdesk.agent.inbound.v1",
                                                     partition: 7, offset: 42) })

      expect(publish(item).status).to eq(:published)
      expect(audits("agent_event.published").sole.data["broker_status"]).to eq("duplicate")
    end
  end

  describe "falha de dependência (RN-43, 07 seção 6)" do
    it "Kafka sem confirmação (503): agenda nova tentativa em 1 s e registra a origem do erro" do
      item = open_event
      stub_broker({ status: 503 })

      result = publish(item)

      expect(result.status).to eq(:retry_scheduled)
      expect(item.reload).to have_attributes(completed_at: nil, published_at: nil, attempts: 1, lease_until: nil,
                                             next_attempt_at: start + 1.second)
      expect(item.last_error).to include("Kafka")
      expect(audits("agent_event.publish_failed").sole.data).to include(
        "attempt" => 1, "origin" => "kafka", "http_status" => 503, "retry" => true,
        "next_attempt_at" => (start + 1.second).utc.iso8601(3)
      )
    end

    it "broker fora do ar (conexão recusada) é falha transitória com origem no broker" do
      item = open_event
      stub_request(:post, BrokerHelpers::BROKER_URL).to_raise(Errno::ECONNREFUSED)

      publish(item)

      expect(audits("agent_event.publish_failed").sole.data).to include("origin" => "broker_indisponivel",
                                                                         "http_status" => nil, "retry" => true)
    end

    it "timeout do broker é falha transitória" do
      item = open_event
      stub_request(:post, BrokerHelpers::BROKER_URL).to_timeout

      expect(publish(item).status).to eq(:retry_scheduled)
      expect(audits("agent_event.publish_failed").sole.data["origin"]).to eq("broker_indisponivel")
    end

    it "429 é falha transitória (RN-43)" do
      item = open_event
      stub_broker({ status: 429, body: "{}" })

      expect(publish(item).status).to eq(:retry_scheduled)
    end

    it "invariante 3: a retentativa reenvia o mesmo corpo, a mesma assinatura de conteúdo e o mesmo event_id" do
      item = open_event
      stub_broker({ status: 503 }, { status: 200 })
      publish(item)

      expect(publish(item).status).to eq(:not_due)
      travel 1.second
      publish(item)

      first, second = broker_requests
      expect(second.body).to eq(first.body)
      expect(second.headers["X-Helpdesk-Event-Id"]).to eq(first.headers["X-Helpdesk-Event-Id"])
      expect(second.headers["Traceparent"]).to eq(first.headers["Traceparent"])
      expect(item.reload).to have_attributes(attempts: 2, published_at: start + 1.second)
    end

    it "RNF-16: o backoff dobra a cada falha (1, 2, 4, 8, 16 s) e para depois de 5 retentativas" do
      item = open_event
      AiTurn.find_by!(event_id: item.id).update_columns(deadline_at: start + 1.hour)
      stub_broker({ status: 503 })
      waits = []

      6.times do
        publish(item)
        item.reload
        waits << (item.next_attempt_at - Time.current).round(3) unless item.completed_at
        travel_to(item.next_attempt_at)
      end

      expect(waits).to eq([ 1, 2, 4, 8, 16 ])
      expect(item).to have_attributes(attempts: 6, published_at: nil)
      expect(item.completed_at).to be_present
      expect(audits("agent_event.publish_failed").last.data).to include("attempt" => 6, "retry" => false,
                                                                        "outcome" => "retentativas_esgotadas")
    end

    it "RN-43: o jitter só aumenta a espera, até 25% da base" do
      item = open_event
      stub_broker({ status: 503 })

      described_class.call(item.id, jitter: -> { 1.0 })

      expect(item.reload.next_attempt_at).to eq(start + 1.25.seconds)
    end
  end

  describe "falha permanente (RN-44): sem retentativa" do
    it "assinatura recusada (401)" do
      item = open_event
      stub_broker({ status: 401 })

      expect(publish(item).status).to eq(:rejected)
      expect(item.reload).to have_attributes(attempts: 1, published_at: nil)
      expect(item.completed_at).to eq(start)
      expect(audits("agent_event.rejected").sole.data).to include("origin" => "assinatura", "http_status" => 401,
                                                                  "reason" => "nao_confere")
    end

    it "contrato recusado pelo broker (422), que manda o evento para a DLQ" do
      item = open_event
      stub_broker({ status: 422 })

      expect(publish(item).status).to eq(:rejected)
      expect(audits("agent_event.rejected").sole.data).to include("origin" => "contrato", "http_status" => 422,
                                                                  "violations" => [ "/turn" ])
    end

    it "invariante 10: evento fora do contrato na saída nem chega ao broker" do
      item = open_event
      item.update_columns(payload: item.payload.except("turn"))
      stub_broker

      expect(publish(item).status).to eq(:rejected)
      expect(broker_requests).to be_empty
      expect(audits("agent_event.rejected").sole.data).to include("origin" => "plataforma", "violations" => [ "/turn" ])
    end
  end

  describe "revalidação antes de publicar (07, seção 6: broker volta com backlog)" do
    it "RN-56: turno superado por mensagem nova não é publicado" do
      item = open_event("meu repasse não caiu")
      ingest("é o de ontem", trace_id:)
      stub_broker

      expect(publish(item).status).to eq(:discarded)
      expect(broker_requests).to be_empty
      expect(item.reload.completed_at).to eq(start)
      expect(audits("agent_event.discarded").sole.data).to include("reason" => "turno_superseded")
    end

    it "tempo no limite (RN-46): publica a 1 ms do prazo e descarta no prazo" do
      on_time = open_event("um", identity: "acc_a")
      late = open_event("dois", identity: "acc_b")
      stub_broker

      travel_to(start + 30.seconds - 0.001, with_usec: true)
      expect(publish(on_time).status).to eq(:published)
      travel_to(start + 30.seconds, with_usec: true)
      expect(publish(late).status).to eq(:discarded)
      expect(audits("agent_event.discarded").sole.data).to include("reason" => "prazo_vencido")
    end

    it "não agenda retentativa para depois do prazo do turno" do
      item = open_event
      stub_broker({ status: 503 })
      travel_to(start + 29.5.seconds)

      expect(publish(item).status).to eq(:expired)
      expect(item.reload.completed_at).to be_present
      expect(audits("agent_event.publish_failed").sole.data).to include("retry" => false, "outcome" => "prazo_vencido")
    end

    it "atribuição mudou desde o turno: não publica" do
      item = open_event
      item.ticket.update_columns(assignment_version: 1)
      stub_broker

      expect(publish(item).status).to eq(:discarded)
      expect(audits("agent_event.discarded").sole.data).to include("reason" => "atribuicao_mudou")
    end
  end

  describe "marca errada" do
    it "ADR-014: a auditoria da publicação fica na marca do atendimento" do
      create(:brand, :jim)
      item = open_event("oi", brand: "jim")
      stub_broker

      publish(item)

      expect(audits("agent_event.published").sole.brand.slug).to eq("jim")
      expect(JSON.parse(broker_requests.sole.body)["brand"]).to eq("jim")
    end
  end

  describe "concorrência e transação", :concurrency do
    it "dois workers com o mesmo item fazem uma chamada só (reserva do item)" do
      item = open_event
      gate = Queue.new
      started = Queue.new
      stub_request(:post, BrokerHelpers::BROKER_URL).to_return do
        started << true
        gate.pop
        broker_response(status: 200)
      end

      first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { publish(item) } }
      started.pop
      second = ActiveRecord::Base.connection_pool.with_connection { publish(item) }
      gate << true

      expect(second.status).to eq(:skipped)
      expect(first.value.status).to eq(:published)
      expect(WebMock).to have_requested(:post, BrokerHelpers::BROKER_URL).once
    end

    it "invariante 2: nenhuma transação aberta durante a chamada ao broker" do
      item = open_event
      open_during_call = nil
      stub_request(:post, BrokerHelpers::BROKER_URL).to_return do
        open_during_call = ActiveRecord::Base.connection.transaction_open?
        broker_response(status: 200)
      end

      publish(item)

      expect(open_during_call).to be(false)
    end

    it "reserva vencida (worker caiu no meio) permite outra tentativa" do
      item = open_event
      item.update_columns(lease_until: start - 1.second, attempts: 1)
      stub_broker

      expect(publish(item).status).to eq(:published)
      expect(item.reload.attempts).to eq(2)
    end
  end
end
