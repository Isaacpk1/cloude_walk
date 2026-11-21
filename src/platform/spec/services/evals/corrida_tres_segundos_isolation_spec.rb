require "rails_helper"

# ADR-023, item 5: o eval roda com a pilha real no ar (scheduler, worker, broker e agent-mock do Compose). O
# atendimento do eval nasce marcado (tickets.evaluation, gravado no commit da primeira mensagem a partir da
# conta de provedor de eval da marca): o worker não publica o turno dele no broker e não entrega a saída dele
# ao canal. Uma ação de outro agente no atendimento torna a execução `error` (cenário contaminado).
#
# A "pilha real" é simulada a cada passo do sleeper: o scheduler (DispatchDue global) e o worker (OutboxJob
# para tudo o que foi enfileirado). O broker simulado entrega o evento ao "agent-mock", que responde na hora
# pelo consumer (AgentActions::Apply), como no Compose com o perfil padrão.
RSpec.describe "ADR-023: eval isolado da pilha real" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:clock) { -> { Time.current } }
  let(:broker_calls) { [] }

  before do
    travel_to(Time.utc(2026, 11, 21, 13, 40, 0), with_usec: true)
    allow(DatabaseClock).to receive(:now) { Time.current }
    stub_request(:post, BrokerHelpers::BROKER_URL).to_return do |request|
      broker_calls << request
      turn = AiTurn.find_by!(event_id: request.headers["X-Helpdesk-Event-Id"])
      AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT) # agent-mock
      broker_response(status: 200)
    end
    stub_channels({ status: 200 })
  end

  # Uma volta do scheduler e do worker reais.
  def drain_stack
    Deadlines::DispatchDue.call(now: Time.current, limit: 100)
    3.times do
      ids = enqueued_jobs.map { _1[:args].first }.uniq
      clear_enqueued_jobs
      ids.each { OutboxJob.perform_now(_1) }
    end
  end

  let(:real_stack) do
    lambda do |seconds|
      travel_to(Time.current + seconds, with_usec: true) if seconds.positive?
      drain_stack
    end
  end

  def run_eval(sleeper: real_stack) = Evals::Runner.call("corrida-3s", brand: infinitepay, clock:, sleeper:)

  describe "com o worker e o agent-mock reais ativos" do
    it "passa: nada vai ao broker nem ao canal, e o turno do eval é descartado como eval" do
      run = run_eval
      drain_stack # o worker ainda pega a saída do turno 2 depois do fim do cenário

      expect(run.status).to eq("passed"), run.checks.reject { _1["ok"] }.inspect
      expect(run.observed["foreign_agent_actions"]).to eq(0)
      expect(broker_calls).to be_empty
      expect(channel_requests).to be_empty
      expect(Delivery.where(ticket_id: run.ticket_id).pluck(:status)).to eq([ "cancelled" ])

      discarded = AuditEvent.where(ticket_id: run.ticket_id, event_type: "agent_event.discarded")
      expect(discarded.map { _1.data["reason"] }).to include("eval")
      expect(AuditEvent.where(ticket_id: run.ticket_id, event_type: "agent_event.published")).to be_empty
      cancelled = AuditEvent.find_by!(ticket_id: run.ticket_id, event_type: "delivery.cancelled")
      expect(cancelled).to have_attributes(brand_id: infinitepay.id, trace_id: be_present)
      expect(cancelled.data).to include("reason" => "eval", "seq" => 3)
      expect(OutboxEvent.where(ticket_id: run.ticket_id, completed_at: nil)).to be_empty
    end

    it "o atendimento do eval nasce marcado no commit da primeira mensagem, pela conta de eval da marca" do
      marked = nil
      sleeper = lambda do |seconds|
        marked = Ticket.order(:id).last.evaluation if marked.nil?
        real_stack.call(seconds)
      end

      run = run_eval(sleeper:)

      expect(marked).to be(true)
      expect(run.ticket.evaluation).to be(true)
      account = ProviderAccount.find_by!(slug: "infinitepay-chat-eval")
      expect(account).to have_attributes(brand_id: infinitepay.id, channel: "chat", evaluation: true, active: false)
      expect(run.ticket.messages.where(direction: "inbound").pluck(:provider_account).uniq).to eq([ account.slug ])
    end
  end

  describe "o OutboxJob acordado pelo próprio eval roda no meio do cenário" do
    it "o DispatchDue do eval acorda o worker, que abre e publica na hora: o turno é descartado, sem broker; passa" do
      # O Sidekiq pega o job assim que é enfileirado (depois do commit), antes de o eval seguir.
      allow(OutboxJob).to receive(:perform_later) { |id| OutboxJob.perform_now(id) }
      allow(OutboxJob).to receive(:set).and_return(OutboxJob)

      run = run_eval(sleeper: ->(seconds) { travel_to(Time.current + seconds, with_usec: true) if seconds.positive? })

      expect(run.status).to eq("passed"), run.checks.reject { _1["ok"] }.inspect
      expect(broker_calls).to be_empty
      reasons = AuditEvent.where(ticket_id: run.ticket_id, event_type: "agent_event.discarded").map { _1.data["reason"] }
      expect(reasons).to eq(%w[eval eval])
      expect(run.observed["deliveries"]).to eq([ { "seq" => 3, "turn" => 2, "status" => "cancelled", "reason" => "eval" } ])
    end
  end

  describe "saída do eval (ADR-023, item 5)" do
    let(:plain) { ->(seconds) { travel_to(Time.current + seconds, with_usec: true) if seconds.positive? } }

    it "o webhook cru do eval é um webhook de chat válido, com customer_ref, como o da ingestão real" do
      run = run_eval(sleeper: plain)

      payloads = run.ticket.messages.where(direction: "inbound").order(:seq).map(&:provider_payload)
      expect(payloads.size).to eq(2)
      payloads.each { expect(HelpdeskContracts.errors(:chat_webhook, _1)).to be_empty }
      expect(payloads.map { _1["customer_ref"] }.uniq.size).to eq(1)
    end

    it "o eval conclui a própria saída pelo worker: cancelled eval no observado, sem delivery.failed nem chamada ao canal" do
      run = run_eval(sleeper: plain)

      expect(run.status).to eq("passed")
      expect(run.observed["deliveries"]).to eq([ { "seq" => 3, "turn" => 2, "status" => "cancelled", "reason" => "eval" } ])
      expect(AuditEvent.where(ticket_id: run.ticket_id, event_type: "delivery.failed")).to be_empty
      expect(channel_requests).to be_empty
    end

    it "Deliveries::Send cancela a saída do eval antes de montar a requisição, mesmo sem customer_ref" do
      ProviderAccount.evaluation_for!(infinitepay, "chat")
      msg = normalized_message(identity: "eval_sem_ref").merge("provider_account" => "infinitepay-chat-eval")
      ticket = Ingestion::Receive.call(msg, provider_payload: {}).ticket
      delivery = requested_delivery(ticket)
      expect(Deliveries::Request).not_to receive(:build)

      result = Deliveries::Send.call(delivery_item(delivery).id)

      expect(result.status).to eq(:cancelled)
      expect(delivery.reload).to have_attributes(status: "cancelled", last_error: "eval")
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "delivery.failed")).to be_empty
      expect(channel_requests).to be_empty
    end
  end

  describe "painel (bloco 05): os motivos eval têm rótulo", type: :request do
    it "a conversa mostra a saída cancelada pelo eval e a linha do tempo, o descarte da publicação e o cancelamento" do
      run = run_eval
      drain_stack

      get conversation_path(run.ticket_id)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css(".delivery--cancelled .delivery__reason")&.text).to include("Atendimento de eval")

      get timeline_path(run.ticket_id)
      expect(response.body).to include("Publicação cancelada", "Entrega cancelada", "Atendimento de eval")
    end
  end

  describe "cenário contaminado" do
    it "uma ação de outro agente no atendimento do eval torna a execução error, não failed" do
      injected = false
      sleeper = lambda do |seconds|
        real_stack.call(seconds)
        turn = AiTurn.where(brand_id: infinitepay.id).order(:id).last
        next if injected || turn.nil? || !turn.eligible?

        injected = true # outro agente responde ao turno 1 por fora (ex.: um consumer antigo)
        AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)
      end

      run = run_eval(sleeper:)

      expect(injected).to be(true)
      expect(run.status).to eq("error")
      expect(run.error).to start_with("cenário contaminado: ")
      expect(run.observed["foreign_agent_actions"]).to be_positive
      expect(EvalRun.count).to eq(1)
    end
  end

  describe "atendimento normal continua saindo" do
    let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

    it "publica o turno no broker e entrega a saída ao canal" do
      ticket = customer_message("meu repasse não caiu").ticket
      travel_to(Time.current + 2.seconds, with_usec: true)
      drain_stack
      drain_stack

      expect(ticket.reload.evaluation).to be(false)
      expect(broker_calls.size).to eq(1)
      expect(AuditEvent.where(ticket_id: ticket.id, event_type: "agent_event.published").count).to eq(1)
      expect(channel_requests.size).to eq(1)
      expect(Delivery.where(ticket_id: ticket.id).pluck(:status)).to eq([ "delivered" ])
    end
  end
end
