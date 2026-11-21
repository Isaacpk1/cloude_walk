require "stringio"

# Cenários de rajada do simulador (ROADMAP, bloco 06, Frontend; RN-55, RN-56; 07, seção 3.4).
# Relógio e espera injetados: a espera avança o relógio congelado, sem sleep (AGENTS.md, regra 3).
RSpec.describe ChannelsMock::Scenarios do
  let(:start) { Time.utc(2026, 11, 20, 12, 0, 0) }
  let(:webhook_url) { "http://localhost:3000/webhooks/chat/infinitepay-chat-mock" }
  let(:jim_url) { "http://localhost:3000/webhooks/chat/jim-chat-mock" }
  let(:log) { StringIO.new }
  let(:waits) { [] }
  # Espera de teste: registra o horário pedido e avança o relógio até ele.
  let(:waiter) do
    lambda do |at|
      waits << at
      ChannelsMock::Clock.freeze(at) if at > ChannelsMock::Clock.now
    end
  end

  before { described_class.reset!(mode: :manual, waiter:, out: log) }
  after { described_class.reset!(mode: :manual) }

  def run_scenario(name, account: "infinitepay-chat-mock", account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021")
    described_class.start(name, account:, account_id:, customer_ref:)
  end

  # Corpos dos webhooks na ordem em que a plataforma os recebeu, com o horário da assinatura.
  def webhooks(url = webhook_url)
    requests = []
    WebMock::RequestRegistry.instance.requested_signatures.hash.each do |signature, count|
      count.times { requests << signature } if signature.uri.to_s == "#{url}:80" || signature.uri.to_s == url
    end
    requests.map do |request|
      body = JSON.parse(request.body)
      t = request.headers["X-Helpdesk-Signature"][/t=(\d+)/, 1].to_i
      body.merge("signed_at" => t)
    end.sort_by { _1["sent_at"] }
  end

  def accept_all(url = webhook_url)
    stub_request(:post, url).to_return(status: 202, body: { status: "accepted", ticket_id: 41 }.to_json)
  end

  describe "RN-56: corrida dos 3 s" do
    it "envia \"meu repasse não caiu\" em t=0 e \"é o de ontem, R$ 1.200\" em t=3 s" do
      accept_all
      run = run_scenario("corrida-3s")

      described_class.drain!

      sent = webhooks
      expect(sent.map { _1["text"] }).to eq([ "meu repasse não caiu", "é o de ontem, R$ 1.200" ])
      expect(sent.map { _1["sent_at"] }).to eq([ "2026-11-20T12:00:00.000Z", "2026-11-20T12:00:03.000Z" ])
      expect(sent.map { _1["signed_at"] }).to eq([ start.to_i, start.to_i + 3 ])
      expect(waits).to eq([ start, start + 3 ])
      expect(run.snapshot).to include("status" => "finished", "scenario" => "corrida-3s", "current_step" => 2)
    end

    it "usa a mesma conta do provedor, o mesmo account_id e o mesmo customer_ref em todos os passos" do
      accept_all
      run_scenario("corrida-3s")

      described_class.drain!

      expect(webhooks.map { _1.values_at("account_id", "customer_ref") }.uniq).to eq([ %w[acc_infinitepay_000021 cus_ref_000021] ])
      expect(webhooks.map { _1["message_id"] }.uniq.size).to eq(2)
    end

    it "assina cada envio com o segredo da conta e manda o contrato de entrada do chat" do
      accept_all
      run_scenario("corrida-3s")

      described_class.drain!

      expect(WebMock).to(have_requested(:post, webhook_url).twice.with do |request|
        HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"],
                                             secret: "dev-secret-infinitepay-chat-mock", now: ChannelsMock::Clock.now)
        HelpdeskContracts.valid?(:chat_webhook, JSON.parse(request.body))
      end)
    end

    it "guarda o horário planejado, o real, o HTTP e a mensagem no simulador, como o formulário" do
      accept_all
      late = ->(at) { ChannelsMock::Clock.freeze(at + 0.04) }
      described_class.reset!(mode: :manual, waiter: late, out: log)
      run = run_scenario("corrida-3s")

      described_class.drain!

      steps = run.snapshot["steps"]
      expect(steps.map { _1["planned_at"] }).to eq([ "2026-11-20T12:00:00.000Z", "2026-11-20T12:00:03.000Z" ])
      expect(steps.map { _1["sent_at"] }).to eq([ "2026-11-20T12:00:00.040Z", "2026-11-20T12:00:03.040Z" ])
      expect(steps.map { _1["http_status"] }).to eq([ 202, 202 ])
      expect(steps.map { _1["outcome"] }).to eq(%w[Confirmada Confirmada])
      inbox = ChannelsMock::Inbox.all
      expect(inbox.map { _1.payload["message_id"] }).to match_array(steps.map { _1["message_id"] })
      expect(inbox.map { _1.payload["text"] }).to match_array([ "meu repasse não caiu", "é o de ontem, R$ 1.200" ])
    end

    it "não envia o passo antes do horário planejado (tempo no limite)" do
      accept_all
      run = run_scenario("corrida-3s")

      described_class.drain!

      run.snapshot["steps"].each { |step| expect(Time.iso8601(step["sent_at"])).to be >= Time.iso8601(step["planned_at"]) }
    end
  end

  describe "RN-55: rajada curta" do
    it "envia três mensagens em t=0, 0,5 s e 1,0 s, na ordem" do
      accept_all
      run_scenario("rajada-curta")

      described_class.drain!

      expect(webhooks.map { _1["sent_at"] }).to eq(%w[2026-11-20T12:00:00.000Z 2026-11-20T12:00:00.500Z 2026-11-20T12:00:01.000Z])
      expect(webhooks.size).to eq(3)
    end
  end

  describe "RN-55: rajada longa (teto de 4 s)" do
    it "envia uma mensagem por segundo de t=0 a t=5 s" do
      accept_all
      run_scenario("rajada-longa")

      described_class.drain!

      expect(webhooks.map { Time.iso8601(_1["sent_at"]) - start }).to eq([ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0 ])
    end
  end

  describe "falha da plataforma num passo" do
    it "registra a falha e continua os próximos passos" do
      stub_request(:post, webhook_url)
        .to_raise(Errno::ECONNREFUSED).then
        .to_return(status: 202, body: { status: "accepted", ticket_id: 41 }.to_json)
      run = run_scenario("corrida-3s")

      described_class.drain!

      steps = run.snapshot["steps"]
      expect(steps.map { _1["http_status"] }).to eq([ nil, 202 ])
      expect(steps.first).to include("outcome" => "Plataforma indisponível")
      expect(steps.first["error"]).to match(/Connection refused/)
      expect(run.snapshot["status"]).to eq("finished")
    end

    it "registra 5xx da plataforma e segue" do
      stub_request(:post, webhook_url).to_return({ status: 503, body: "{}" }, { status: 202, body: "{}" })
      run = run_scenario("corrida-3s")

      described_class.drain!

      expect(run.snapshot["steps"].map { _1["outcome"] }).to eq([ "Erro 503", "Confirmada" ])
    end

    it "um erro inesperado no envio vira erro do passo, sem derrubar a execução" do
      sender = ->(**) { raise "quebrou" }
      described_class.reset!(mode: :manual, waiter:, out: log, sender:)
      run = run_scenario("rajada-curta")

      described_class.drain!

      expect(run.snapshot["steps"].map { _1["error"] }).to eq([ "quebrou" ] * 3)
      expect(run.snapshot["status"]).to eq("finished")
    end
  end

  describe "dois cenários ao mesmo tempo em contas diferentes" do
    it "intercala os envios pelo horário planejado sem misturar conta, cliente nem execução" do
      accept_all
      accept_all(jim_url)
      a = run_scenario("corrida-3s")
      ChannelsMock::Clock.advance(1)
      b = run_scenario("rajada-curta", account: "jim-chat-mock", account_id: "acc_jim_000007", customer_ref: "cus_ref_000007")

      described_class.drain!

      expect(waits).to eq([ start, start + 1, start + 1.5, start + 2, start + 3 ])
      expect(webhooks.map { _1["account_id"] }.uniq).to eq(%w[acc_infinitepay_000021])
      expect(webhooks(jim_url).map { _1["account_id"] }.uniq).to eq(%w[acc_jim_000007])
      expect(webhooks(jim_url).map { _1["sent_at"] }).to eq(%w[2026-11-20T12:00:01.000Z 2026-11-20T12:00:01.500Z 2026-11-20T12:00:02.000Z])
      expect(a.snapshot["steps"].map { _1["message_id"] }).to all(satisfy { |id| ChannelsMock::Inbox.all.find { _1.payload["message_id"] == id }.account == "infinitepay-chat-mock" })
      expect(b.snapshot["steps"].map { _1["message_id"] }).to all(satisfy { |id| ChannelsMock::Inbox.all.find { _1.payload["message_id"] == id }.account == "jim-chat-mock" })
      expect(a.id).not_to eq(b.id)
    end
  end

  describe "validação na largada" do
    it "recusa cenário desconhecido" do
      expect { run_scenario("outro") }.to raise_error(described_class::UnknownScenario)
    end

    it "recusa conta do provedor fora da lista" do
      expect { run_scenario("corrida-3s", account: "outra") }.to raise_error(ArgumentError, /conta/)
    end

    it "recusa cliente fora do contrato antes de enviar qualquer passo" do
      expect { run_scenario("corrida-3s", account_id: "") }.to raise_error(HelpdeskContracts::InvalidPayload)
      expect(described_class.runs).to be_empty
    end
  end

  describe "repetição" do
    it "disparar o mesmo cenário duas vezes gera execuções e message_id diferentes" do
      accept_all
      first = run_scenario("corrida-3s")
      described_class.drain!
      second = run_scenario("corrida-3s")
      described_class.drain!

      expect(second.id).to eq(first.id + 1)
      ids = (first.snapshot["steps"] + second.snapshot["steps"]).map { _1["message_id"] }
      expect(ids.uniq.size).to eq(4)
      expect(second.snapshot["steps"].first["planned_at"]).to eq("2026-11-20T12:00:03.000Z")
    end
  end

  describe "RN-51: logs JSON sem o texto da mensagem" do
    it "registra cada passo em JSON, com trace_id, sem o texto" do
      accept_all
      run_scenario("corrida-3s")

      described_class.drain!

      lines = log.string.lines.map { JSON.parse(_1) }
      steps = lines.select { _1["event"] == "scenario.step_sent" }
      expect(steps.size).to eq(2)
      expect(steps.first).to include("scenario" => "corrida-3s", "step" => 1, "http_status" => 202, "account" => "infinitepay-chat-mock")
      expect(steps.first["trace_id"]).to match(/\A\h{32}\z/)
      expect(log.string).not_to include("repasse", "1.200", "acc_infinitepay_000021", "cus_ref_000021")
    end
  end

  describe "espera real" do
    it "só volta quando o relógio alcança o horário planejado, mesmo se o sono acordar antes" do
      naps = []
      sleeper = lambda do |seconds|
        naps << seconds
        ChannelsMock::Clock.advance(naps.size == 1 ? 0.5 : seconds) # acorda cedo na primeira vez
      end

      described_class.wait_until(start + 2, sleeper:)

      expect(ChannelsMock::Clock.now).to be >= start + 2
      expect(naps.first).to eq(2.0)
      expect(naps).to eq([ 2.0, 1.5 ])
    end

    it "não dorme quando o horário já passou" do
      sleeper = ->(_) { raise "não devia dormir" }

      expect { described_class.wait_until(start - 1, sleeper:) }.not_to raise_error
    end
  end

  describe "modo thread" do
    it "executa a execução em segundo plano e termina com todos os passos" do
      accept_all
      described_class.reset!(mode: :thread, waiter:, out: log)
      run = run_scenario("corrida-3s")

      run.join(5)

      expect(run.snapshot["status"]).to eq("finished")
      expect(webhooks.size).to eq(2)
    end
  end
end
