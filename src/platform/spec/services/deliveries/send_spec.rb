require "rails_helper"

RSpec.describe Deliveries::Send, "RF-06, RNF-15: envio ordenado da saída ao provedor do chat (07, seção 3.2)" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let(:start) { Time.zone.parse("2026-11-20T13:40:00Z") }
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:jitter) { -> { 0.0 } }
  let!(:inbound) { customer_message(external_id: "chat_msg_000123") }
  let(:ticket) { inbound.ticket }

  around { |example| travel_to(start) { example.run } }

  def send_delivery(delivery) = described_class.call(delivery_item(delivery).id, jitter:)
  def audits(type) = AuditEvent.where(event_type: type).order(:id)

  describe "caminho feliz" do
    it "envia o corpo no contrato chat_send, assinado com o segredo da conta, e marca delivered com a confirmação" do
      delivery = requested_delivery(ticket, trace_id:)
      stub_channels(status: 200, message_id: "chat_out_000456")

      result = send_delivery(delivery)

      request = channel_requests.sole
      expect { verify_channel_request!(request, secret: account.secret) }.not_to raise_error
      expect(request.uri.to_s).to eq("#{DeliveryHelpers::CHANNELS_URL}/provider/chat/infinitepay-chat-mock/messages")
      expect(JSON.parse(request.body)).to eq("customer_ref" => "cus_ref_000021", "text" => "Seu repasse cai hoje até as 18h.",
                                             "reply_to" => "chat_msg_000123")
      expect(request.headers).to include("Content-Type" => "application/json", "Idempotency-Key" => delivery.delivery_id,
                                         "X-Conversation-Id" => "tkt_#{ticket.id}", "X-Conversation-Seq" => delivery.seq.to_s)
      expect(request.headers["Traceparent"]).to match(/\A00-#{trace_id}-\h{16}-01\z/)
      expect(result.status).to eq(:delivered)
      expect(delivery.reload).to have_attributes(status: "delivered", provider_message_id: "chat_out_000456",
                                                 delivered_at: start, attempts: 1, lease_until: nil, last_error: nil)
      expect(delivery_item(delivery)).to have_attributes(completed_at: start, lease_until: nil)
    end

    it "RF-54, RF-56: audita sending e delivered com o trace_id da entrega" do
      delivery = requested_delivery(ticket, trace_id:)
      stub_channels

      send_delivery(delivery)

      expect(audits("delivery.sending").sole).to have_attributes(trace_id:, brand_id: infinitepay.id, ticket_id: ticket.id,
                                                                 actor_type: "system")
      expect(audits("delivery.sending").sole.data).to eq("delivery_id" => delivery.delivery_id, "seq" => delivery.seq,
                                                         "attempt" => 1)
      expect(audits("delivery.delivered").sole.data).to include(
        "delivery_id" => delivery.delivery_id, "seq" => delivery.seq, "attempt" => 1,
        "provider_message_id" => "chat_out_000456", "replayed" => false, "duration_ms" => 0
      )
    end

    it "invariante 2: nenhuma chamada HTTP com transação aberta" do
      delivery = requested_delivery(ticket)
      stub_channels

      send_delivery(delivery)

      expect(transactions_during_http).to eq([ 0 ])
    end

    it "invariante 13, RN-51: loga em JSON com trace_id, delivery_id, seq e tentativa, sem o texto nem o customer_ref" do
      delivery = requested_delivery(ticket, trace_id:)
      stub_channels
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, msg| lines << msg; m.call(msg) }

      send_delivery(delivery)

      expect(lines.filter_map { JSON.parse(_1) rescue nil }).to include(
        a_hash_including("event" => "delivery.delivered", "trace_id" => trace_id, "delivery_id" => delivery.delivery_id,
                         "seq" => delivery.seq, "attempt" => 1, "status" => "delivered")
      )
      expect(lines.join).not_to include("Seu repasse", "cus_ref_000021")
    end

    it "reply_to é a mensagem do cliente no context_until_seq do turno aplicado, não a última" do
      customer_message("é o de ontem", external_id: "chat_msg_000124")
      delivery = requested_delivery(ticket, context_until_seq: inbound.seq)
      stub_channels

      send_delivery(delivery)

      expect(JSON.parse(channel_requests.sole.body)["reply_to"]).to eq("chat_msg_000123")
    end

    it "sem o registro do turno, reply_to é a última mensagem do cliente antes da saída" do
      customer_message("é o de ontem", external_id: "chat_msg_000124")
      delivery = requested_delivery(ticket, audit: false)
      stub_channels

      send_delivery(delivery)

      expect(JSON.parse(channel_requests.sole.body)["reply_to"]).to eq("chat_msg_000124")
    end
  end

  describe "RN-47: repetição" do
    it "o job repetido com a entrega já delivered não chama o provedor de novo" do
      delivery = requested_delivery(ticket)
      stub_channels
      send_delivery(delivery)

      result = send_delivery(delivery)

      expect(channel_requests.size).to eq(1)
      expect(result.status).to eq(:skipped)
      expect(audits("delivery.delivered").count).to eq(1)
    end

    it "item aberto de uma entrega já encerrada (ex.: cancelada no handoff) só é concluído" do
      delivery = requested_delivery(ticket)
      delivery.update_columns(status: "cancelled")
      stub_channels

      result = send_delivery(delivery)

      expect(channel_requests).to be_empty
      expect(result.status).to eq(:already_closed)
      expect(delivery_item(delivery).completed_at).to eq(start)
    end
  end

  describe "07, seção 3.2: ordem de entrega por seq" do
    it "a segunda saída não sai antes da primeira e fica com um despertador no outbox" do
      first = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels

      result = send_delivery(second)

      expect(channel_requests).to be_empty
      expect(result.status).to eq(:waiting_previous)
      expect(second.reload.status).to eq("pending")
      expect(delivery_item(second)).to have_attributes(completed_at: nil, next_attempt_at: start + Deliveries::Policy::ORDER_RECHECK)
      expect(first.reload.status).to eq("pending")
    end

    it "ao entregar a primeira, acorda a segunda (próximo item no outbox para agora e job enfileirado)" do
      first = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels({ status: 200, message_id: "m1" }, { status: 200, message_id: "m2" })
      send_delivery(second)
      clear_enqueued_jobs

      send_delivery(first)

      expect(delivery_item(second).next_attempt_at).to eq(start)
      expect(OutboxJob).to have_been_enqueued.with(delivery_item(second).id)
      expect(send_delivery(second).status).to eq(:delivered)
      expect(channel_requests.map { JSON.parse(_1.body)["text"] }).to eq([ "Seu repasse cai hoje até as 18h.", "Mais alguma dúvida?" ])
    end

    it "rejeição definitiva da primeira libera a segunda" do
      first = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels(status: 422)

      send_delivery(first)

      expect(first.reload.status).to eq("failed")
      expect(OutboxJob).to have_been_enqueued.with(delivery_item(second).id)
    end
  end

  describe "RNF-15: confirmação perdida depois de o provedor aceitar" do
    it "repete a mesma chamada com o mesmo Idempotency-Key e marca delivered uma vez" do
      delivery = requested_delivery(ticket)
      stub_channels({ timeout: true }, { status: 200, replayed: true })

      expect(send_delivery(delivery).status).to eq(:retry_scheduled)
      expect(delivery.reload).to have_attributes(status: "sending", lease_until: nil)
      travel 1.second
      expect(send_delivery(delivery).status).to eq(:delivered)

      first, second = channel_requests
      expect(second.headers["Idempotency-Key"]).to eq(first.headers["Idempotency-Key"])
      expect(second.body).to eq(first.body)
      expect(delivery.reload).to have_attributes(status: "delivered", attempts: 2)
      expect(audits("delivery.delivered").sole.data).to include("replayed" => true, "attempt" => 2)
      expect(audits("delivery.retry_scheduled").sole.data["outcome"]).to eq("incerto")
    end
  end

  describe "RNF-15: 504 confirmacao_perdida do channels-mock" do
    it "é transitório; a retentativa recebe 200 com Idempotent-Replayed e marca delivered uma vez" do
      delivery = requested_delivery(ticket)
      stub_channels({ status: 504, body: JSON.generate(error: "confirmacao_perdida") }, { status: 200, replayed: true })

      expect(send_delivery(delivery).status).to eq(:retry_scheduled)
      travel 1.second
      expect(send_delivery(delivery).status).to eq(:delivered)
      expect(channel_requests.map { _1.headers["Idempotency-Key"] }.uniq).to eq([ delivery.delivery_id ])
      expect(audits("delivery.delivered").sole.data["replayed"]).to be(true)
      expect(audits("delivery.retry_scheduled").sole.data["outcome"]).to eq("incerto")
    end
  end

  describe "RN-43, RNF-16: falha transitória" do
    it "503 agenda a retentativa com backoff, mesmo corpo, sem perform_in para o prazo" do
      delivery = requested_delivery(ticket)
      stub_channels({ status: 503 }, { status: 200 })

      result = send_delivery(delivery)

      expect(result).to have_attributes(status: :retry_scheduled, next_attempt_at: start + 1.second)
      expect(delivery.reload).to have_attributes(status: "sending", attempts: 1, lease_until: nil, last_error: "http 503")
      expect(delivery_item(delivery)).to have_attributes(next_attempt_at: start + 1.second, completed_at: nil)
      expect(audits("delivery.retry_scheduled").sole.data).to include(
        "delivery_id" => delivery.delivery_id, "attempt" => 1, "error" => "http 503",
        "next_attempt_at" => (start + 1.second).utc.iso8601(3)
      )
    end

    it "tempo no limite: antes do next_attempt_at não chama; no instante exato, chama" do
      delivery = requested_delivery(ticket)
      stub_channels({ status: 503 }, { status: 200 })
      send_delivery(delivery)

      travel 0.999.seconds, with_usec: true
      expect(send_delivery(delivery)).to have_attributes(status: :not_due, next_attempt_at: start + 1.second)
      expect(channel_requests.size).to eq(1)

      travel_to(start + 1.second)
      expect(send_delivery(delivery).status).to eq(:delivered)
      expect(channel_requests.map(&:body).uniq.size).to eq(1)
    end

    it "backoff 1, 2, 4, 8 e 16 s com jitter, e esgotado com resultado incerto (500) pede conciliação sem acordar a próxima" do
      delivery = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels(*Array.new(6) { { status: 500 } })
      waits = []

      6.times do
        result = described_class.call(delivery_item(delivery).id, jitter: -> { 1.0 })
        break waits << result.status unless result.next_attempt_at

        waits << (result.next_attempt_at - Time.current)
        travel_to(result.next_attempt_at, with_usec: true)
      end

      expect(waits).to eq([ 1.25, 2.5, 5.0, 10.0, 20.0, :reconciliation_needed ])
      expect(delivery.reload).to have_attributes(status: "sending", attempts: 6, lease_until: nil)
      expect(audits("delivery.reconciliation_needed").sole.data).to eq("delivery_id" => delivery.delivery_id, "attempts" => 6)
      expect(delivery_item(delivery)).to have_attributes(completed_at: Time.current, last_error: "reconciliation_needed")
      expect(described_class.call(delivery_item(second).id, jitter:).status).to eq(:waiting_previous)
      expect(channel_requests.size).to eq(6)
    end

    it "timeout e conexão recusada são transitórios" do
      delivery = requested_delivery(ticket)
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_raise(Errno::ECONNREFUSED)

      expect(send_delivery(delivery).status).to eq(:retry_scheduled)
      expect(delivery.reload.last_error).to include("ECONNREFUSED")
    end
  end

  describe "RN-43, 07 seção 3.2: tentativas esgotadas, não entrega certa ou resultado incerto" do
    def exhaust(delivery)
      statuses = []
      Deliveries::Policy::MAX_ATTEMPTS.times do
        result = send_delivery(delivery)
        statuses << result.status
        break unless result.next_attempt_at

        travel_to(result.next_attempt_at, with_usec: true)
      end
      statuses
    end

    def expect_unavailable_and_order_moves_on(delivery, second, http_status:)
      expect(delivery.reload).to have_attributes(status: "failed", attempts: 6, lease_until: nil)
      expect(audits("delivery.failed").sole.data).to include("delivery_id" => delivery.delivery_id, "attempt" => 6,
                                                             "reason" => "provedor_indisponivel", "http_status" => http_status)
      expect(audits("delivery.reconciliation_needed")).to be_empty
      expect(audits("delivery.retry_scheduled").map { _1.data["outcome"] }.uniq).to eq([ "sem_efeito" ])
      expect(delivery_item(delivery)).to have_attributes(completed_at: Time.current, last_error: "provedor_indisponivel")
      expect(OutboxJob).to have_been_enqueued.with(delivery_item(second).id)
      expect(send_delivery(second).status).to eq(:delivered)
    end

    it "6× conexão recusada: failed provedor_indisponivel, e a segunda saída sai" do
      delivery = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_raise(Errno::ECONNREFUSED).times(6)
        .then.to_return(channel_response(status: 200))

      expect(exhaust(delivery).last).to eq(:failed)
      expect_unavailable_and_order_moves_on(delivery, second, http_status: nil)
    end

    it "6× 503 (não processado pelo provedor): failed provedor_indisponivel, e a segunda saída sai" do
      delivery = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_channels(*Array.new(6) { { status: 503 } }, { status: 200 })

      expect(exhaust(delivery).last).to eq(:failed)
      expect_unavailable_and_order_moves_on(delivery, second, http_status: 503)
    end

    it "um timeout de leitura no meio torna o resultado incerto: conciliação, e a segunda não sai" do
      delivery = requested_delivery(ticket)
      second = requested_delivery(ticket, text: "Mais alguma dúvida?")
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return(channel_response(status: 503)).times(2)
        .then.to_raise(Net::ReadTimeout).then.to_return(channel_response(status: 503)).times(3)

      expect(exhaust(delivery).last).to eq(:reconciliation_needed)
      expect(audits("delivery.retry_scheduled").map { _1.data["outcome"] })
        .to eq(%w[sem_efeito sem_efeito incerto sem_efeito sem_efeito])
      expect(delivery.reload).to have_attributes(status: "sending", attempts: 6)
      expect(audits("delivery.failed")).to be_empty
      expect(delivery_item(delivery).last_error).to eq("reconciliation_needed")
      expect(send_delivery(second).status).to eq(:waiting_previous)
    end

    [ [ "5xx diferente de 503", { status: 500 } ], [ "2xx sem message_id", { status: 200, body: "{}" } ],
      [ "conexão cortada depois de enviar", :reset ] ].each do |label, response|
      it "#{label} é incerto" do
        delivery = requested_delivery(ticket)
        stub = stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT)
        response == :reset ? stub.to_raise(Errno::ECONNRESET) : stub.to_return(response)

        expect(send_delivery(delivery).status).to eq(:retry_scheduled)
        expect(audits("delivery.retry_scheduled").sole.data["outcome"]).to eq("incerto")
      end
    end

    it "429 e falha ao abrir a conexão (open timeout, DNS) são sem efeito" do
      delivery = requested_delivery(ticket)
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return(status: 429, body: "{}")
        .then.to_raise(Net::OpenTimeout).then.to_raise(SocketError)
      2.times { travel_to(send_delivery(delivery).next_attempt_at, with_usec: true) }
      send_delivery(delivery)

      expect(audits("delivery.retry_scheduled").map { _1.data["outcome"] }).to eq(%w[sem_efeito sem_efeito sem_efeito])
    end

    it "tentativa abandonada (reserva vencida, sem retry_scheduled) conta como incerta no fim" do
      delivery = requested_delivery(ticket)
      delivery.update_columns(status: "sending", attempts: 5, lease_until: start - 1.second)
      stub_channels({ status: 503 })

      expect(send_delivery(delivery).status).to eq(:reconciliation_needed)
      expect(audits("delivery.failed")).to be_empty
    end
  end

  describe "rejeição definitiva (4xx)" do
    [ [ 409, "seq_anterior", "seq_anterior" ], [ 409, "seq_repetida", "seq_repetida" ], [ 401, "assinatura_invalida", "assinatura" ],
      [ 422, "contrato_invalido", "contrato" ], [ 422, "idempotency_key_reutilizada", "contrato" ],
      [ 422, "recusada_pelo_provedor", "recusada_pelo_provedor" ], [ 404, "conta_desconhecida", "recusada_pelo_provedor" ] ]
      .each do |status, provider_error, reason|
      it "#{status} #{provider_error} marca failed (#{reason}), audita e conclui o item" do
        delivery = requested_delivery(ticket)
        stub_channels(status:, body: JSON.generate(error: provider_error), headers: { "Content-Type" => "application/json" })

        expect(send_delivery(delivery).status).to eq(:failed)
        expect(delivery.reload).to have_attributes(status: "failed", lease_until: nil)
        expect(audits("delivery.failed").sole.data).to include("delivery_id" => delivery.delivery_id, "attempt" => 1,
                                                               "http_status" => status, "reason" => reason,
                                                               "provider_error" => provider_error)
        expect(delivery_item(delivery).completed_at).to eq(start)
      end
    end

    it "invariante 10: corpo fora do contrato chat_send (sem customer_ref) falha sem chamar o provedor" do
      inbound.update_columns(provider_payload: {})
      delivery = requested_delivery(ticket)
      stub_channels

      expect(send_delivery(delivery).status).to eq(:failed)
      expect(channel_requests).to be_empty
      expect(audits("delivery.failed").sole.data).to include("reason" => "plataforma", "http_status" => nil,
                                                             "platform_error" => "fora_do_contrato_chat_send")
      expect(audits("delivery.sending")).to be_empty
    end

    { "canal_sem_adaptador" => ->(d) { d.update_columns(channel: "whatsapp") },
      "conta_inexistente" => ->(d) { d.update_columns(provider_account: "conta-que-nao-existe") } }.each do |platform_error, change|
      it "erro da própria plataforma (#{platform_error}) falha com reason plataforma, sem chamar o provedor" do
        delivery = requested_delivery(ticket).tap { change.call(_1) }
        stub_channels

        expect(send_delivery(delivery).status).to eq(:failed)
        expect(channel_requests).to be_empty
        expect(audits("delivery.failed").sole.data).to include("reason" => "plataforma", "http_status" => nil, "platform_error" => platform_error)
        expect(delivery.reload.last_error).to eq("#{platform_error} (plataforma)")
      end
    end
  end

  describe "07, seção 3.2: reserva (lease) da tentativa" do
    it "não envia enquanto outra tentativa tem a reserva vigente; retoma depois de vencida" do
      delivery = requested_delivery(ticket)
      delivery.update_columns(status: "sending", attempts: 1, lease_until: start + 10.seconds)
      stub_channels

      expect(send_delivery(delivery).status).to eq(:in_flight)
      expect(channel_requests).to be_empty
      expect(delivery_item(delivery).next_attempt_at).to eq(start + 10.seconds)

      travel_to(start + 10.seconds)
      expect(send_delivery(delivery).status).to eq(:in_flight)
      travel_to(start + 10.001.seconds, with_usec: true)
      expect(send_delivery(delivery).status).to eq(:delivered)
      expect(delivery.reload.attempts).to eq(2)
    end

    it "a reserva do envio põe o despertador do item no fim do lease: se o processo cair, a recuperação retoma" do
      delivery = requested_delivery(ticket)
      stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_raise(SignalException.new("TERM"))

      expect { send_delivery(delivery) }.to raise_error(SignalException)
      lease = start + Deliveries::Policy::LEASE
      expect(delivery.reload).to have_attributes(status: "sending", lease_until: lease)
      expect(delivery_item(delivery).next_attempt_at).to eq(lease)

      travel_to(lease + Outbox::Recover::GRACE)
      expect(Outbox::Recover.call).to include(delivery_item(delivery).id)
    end

    it "resultado de uma tentativa superada (outra retomou após o lease) não é aplicado" do
      delivery = requested_delivery(ticket)
      stub_channels(status: 200)
      allow(Deliveries::ChatClient).to receive(:new).and_wrap_original do |m, *args|
        client = m.call(*args)
        allow(client).to receive(:deliver).and_wrap_original do |d, **kw|
          Delivery.where(id: delivery.id).update_all("attempts = attempts + 1")
          d.call(**kw)
        end
        client
      end

      expect(send_delivery(delivery).status).to eq(:superseded)
      expect(delivery.reload.status).to eq("sending")
      expect(audits("delivery.delivered")).to be_empty
    end
  end

  describe "invariante 6: marca errada" do
    it "item de outra marca apontando para a entrega desta não envia nada" do
      jim = create(:brand, :jim)
      create(:provider_account, brand: jim, slug: "jim-chat-mock")
      jim_ticket = customer_message(brand: "jim").ticket
      delivery = requested_delivery(ticket)
      forged = OutboxEvent.create!(brand: jim, ticket: jim_ticket, event_type: described_class::EVENT_TYPE, trace_id: "t",
                                   next_attempt_at: start, payload: { delivery_id: delivery.delivery_id, ticket_id: jim_ticket.id, seq: 9 })
      stub_channels

      expect(described_class.call(forged.id).status).to eq(:discarded)
      expect(channel_requests).to be_empty
      expect(delivery.reload.status).to eq("pending")
      expect(forged.reload.completed_at).to eq(start)
    end
  end
end
