require "rails_helper"

# Pedido explícito de humano na ingestão (RN-34, RF-39; 07, seção 3.2 "Gatilhos" e seção 3.4; critério de aceite de
# RF-39 a RF-42). Na transação da ingestão, com o atendimento travado, depois de gravar a mensagem: caso com a IA pede
# o handoff (Handoff::Request, motivo pedido_do_cliente, origem ingestion) sem abrir ciclo da IA; caso já humano só
# registra o pedido no histórico.
RSpec.describe Ingestion::Receive do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:identity) { "acc_infinitepay_humano" }
  let(:human_text) { "quero falar com um atendente" }

  around { |example| travel_to(t0) { example.run } }

  def message(text, external_id: SecureRandom.uuid, brand: "infinitepay", identity: self.identity)
    normalized_message(text:, brand:, identity:, external_id:)
  end

  def say(text, **) = described_class.call(message(text, **), provider_payload: {})

  def human_audits(ticket) = audits(ticket, "customer.human_requested")

  describe "RN-34: caso novo com a IA" do
    it "pede o handoff pedido_do_cliente pela ingestão, sem turno, e audita handoff_pedido" do
      result = say(human_text)
      ticket = result.ticket.reload

      handoff = handoff_items(ticket).sole
      expect(handoff).to have_attributes(brand_id: infinitepay.id, dedup_key: "handoff:#{ticket.id}:0",
                                         trace_id: result.message.trace_id)
      expect(handoff.payload).to include("reason" => "pedido_do_cliente", "source" => "ingestion", "turn" => nil,
                                         "assignment_version" => 0)
      expect(result.handoff_event_id).to eq(handoff.id)
      expect(human_audits(ticket).sole).to have_attributes(
        trace_id: result.message.trace_id, actor_type: "customer",
        data: { "seq" => 1, "state" => "novo", "outcome" => "handoff_pedido", "outbox_event_id" => handoff.id }
      )
    end

    it "a mensagem não abre o ciclo da IA" do
      ticket = say(human_text).ticket.reload

      expect(ticket).to have_attributes(latest_customer_seq: 1, first_pending_seq: nil, first_pending_at: nil,
                                        dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)
    end

    it "continua gravando a mensagem, o message.received e a versão do contexto" do
      result = say(human_text)

      expect(result).to be_created
      expect(result.message).to have_attributes(seq: 1, body: human_text)
      expect(OutboxEvent.where(ticket: result.ticket).pluck(:event_type))
        .to contain_exactly("message.received", "handoff.requested")
      expect(result.ticket.reload.context_version).to eq(1)
    end

    it "mensagem comum não é pedido: sem handoff nem customer.human_requested" do
      result = say("meu repasse não caiu")

      expect(handoff_items(result.ticket)).to be_empty
      expect(human_audits(result.ticket)).to be_empty
      expect(result.handoff_event_id).to be_nil
    end

    it "acorda o OutboxJob do pedido e o do message.received depois do commit" do
      result = say(human_text)

      expect(OutboxJob).to have_been_enqueued.with(result.outbox_event_id)
      expect(OutboxJob).to have_been_enqueued.with(result.handoff_event_id)
    end
  end

  describe "RN-34, RN-56: pedido durante a geração invalida o turno em andamento" do
    it "o turno eligible expira na hora (pedido_do_cliente) e o pedido leva o número do turno" do
      turn = open_turn_for(say("meu repasse não caiu"))

      result = say(human_text)

      expect(turn.reload.status).to eq("expired")
      expect(audits(turn.ticket, "ai_turn.expired").sole.data).to include("turn" => turn.turn, "reason" => "pedido_do_cliente")
      expect(audits(turn.ticket, "ai_turn.superseded")).to be_empty
      expect(handoff_items(turn.ticket).sole.payload).to include("turn" => turn.turn, "first_pending_seq" => 1)
      expect(human_audits(turn.ticket).sole.data).to include("seq" => 2, "state" => "novo", "outcome" => "handoff_pedido")
      expect(result.ticket.reload.latest_customer_seq).to eq(2)
    end

    it "a resposta atrasada do turno é rejeitada com handoff_pedido, sem saída ao cliente" do
      turn = open_turn_for(say("meu repasse não caiu"))
      say(human_text)

      outcome = AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT)

      expect(outcome).to have_attributes(status: :rejected, reason: "handoff_pedido")
      expect(Message.where(ticket_id: turn.ticket_id, direction: "outbound")).to be_empty
    end

    it "o ciclo já aberto fica como estava para o Escalate encerrar (sem prazos novos)" do
      first = say("meu repasse não caiu").ticket.reload
      before = first.attributes.slice("first_pending_seq", "first_pending_at", "dispatch_due_at", "ai_deadline_at")

      travel 1.second
      ticket = say(human_text).ticket.reload

      expect(ticket.attributes.slice("first_pending_seq", "first_pending_at", "dispatch_due_at", "ai_deadline_at")).to eq(before)
      expect(ticket.progress_due_at).to be_nil # o Request zera o aviso (RN-57)
    end

    it "nenhum turno novo abre depois do pedido (Turns::Open recusa com handoff_pedido)" do
      say("meu repasse não caiu")
      ticket = say(human_text).ticket

      result = Turns::Open.call(due_dispatch(ticket).id)

      expect(result.status).to eq(:handoff_requested)
      expect(ticket.ai_turns).to be_empty
    end
  end

  describe "RN-34: aguardando_cliente com a IA também escala" do
    it "pede o handoff com o estado anterior na auditoria" do
      ticket = say("meu repasse não caiu").ticket
      ticket.update_columns(state: "aguardando_cliente", first_pending_seq: nil, first_pending_at: nil,
                            dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)

      say(human_text)

      expect(handoff_items(ticket).sole.payload).to include("reason" => "pedido_do_cliente")
      expect(human_audits(ticket).sole.data).to include("state" => "aguardando_cliente", "outcome" => "handoff_pedido")
      expect(ticket.reload).to have_attributes(first_pending_seq: nil, dispatch_due_at: nil, ai_deadline_at: nil)
    end
  end

  describe "RF-39 a RF-42 (aceite): repetir o pedido não duplica o handoff" do
    it "segundo pedido na mesma atribuição, antes do Escalate: handoff_ja_pedido, sem outro item" do
      say(human_text)
      result = say("preciso falar com uma pessoa")

      expect(handoff_items(result.ticket).count).to eq(1)
      expect(result.handoff_event_id).to be_nil
      expect(human_audits(result.ticket).map { _1.data["outcome"] }).to eq(%w[handoff_pedido handoff_ja_pedido])
      expect(human_audits(result.ticket).last.data).to include("seq" => 2)
      expect(human_audits(result.ticket).last.data).not_to have_key("outbox_event_id")
      expect(audits(result.ticket, "handoff.requested").count).to eq(1)
    end

    it "pedido com outro gatilho já gravado na atribuição (prazo): handoff_ja_pedido" do
      ticket = say("meu repasse não caiu").ticket
      request_handoff(ticket, reason: "prazo_do_turno")

      say(human_text)

      expect(handoff_items(ticket).sole.payload["reason"]).to eq("prazo_do_turno")
      expect(human_audits(ticket).sole.data["outcome"]).to eq("handoff_ja_pedido")
    end

    it "pedido na fila humana (depois do Escalate): só registrado no histórico, sem pedido novo" do
      default_queue(infinitepay)
      first = say(human_text)
      Handoff::Escalate.call(first.handoff_event_id)
      clear_enqueued_jobs

      result = say(human_text)

      expect(result.ticket.reload).to have_attributes(state: "aguardando_humano", assignment_version: 1)
      expect(handoff_items(result.ticket).count).to eq(1)
      expect(human_audits(result.ticket).last.data)
        .to eq("seq" => 3, "state" => "aguardando_humano", "outcome" => "registrado") # seq 2 é o aviso de transferência
      expect(result.handoff_event_id).to be_nil
      expect(OutboxJob).to have_been_enqueued.exactly(:once).with(result.outbox_event_id)
    end

    it "o mesmo webhook duas vezes: a duplicata não grava auditoria nem pedido" do
      payload = message(human_text, external_id: "chat_msg_humano_1")
      described_class.call(payload, provider_payload: {})
      clear_enqueued_jobs

      result = described_class.call(payload, provider_payload: {})

      expect(result).to be_duplicate
      expect(handoff_items(result.ticket).count).to eq(1)
      expect(human_audits(result.ticket).count).to eq(1)
      expect(OutboxJob).not_to have_been_enqueued
    end
  end

  describe "RN-34: caso já humano só registra o pedido" do
    it "com_analista: auditoria registrado, sem pedido nem prazos" do
      ticket = say("meu repasse não caiu").ticket
      analyst = create(:user)
      ticket.update_columns(state: "com_analista", assignee_id: analyst.id, first_pending_seq: nil, first_pending_at: nil,
                            dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)

      say(human_text)

      expect(handoff_items(ticket)).to be_empty
      expect(human_audits(ticket).sole.data).to eq("seq" => 2, "state" => "com_analista", "outcome" => "registrado")
      expect(ticket.reload).to have_attributes(first_pending_seq: nil, dispatch_due_at: nil)
    end

    it "aguardando_cliente com analista: registrado" do
      ticket = say("meu repasse não caiu").ticket
      ticket.update_columns(state: "aguardando_cliente", assignee_id: create(:user).id)

      say(human_text)

      expect(handoff_items(ticket)).to be_empty
      expect(human_audits(ticket).sole.data["outcome"]).to eq("registrado")
    end

    it "resolvido: registrado no mesmo atendimento, sem reabrir para a IA" do
      ticket = say("meu repasse não caiu").ticket
      ticket.update_columns(state: "resolvido", first_pending_seq: nil, first_pending_at: nil, dispatch_due_at: nil,
                            ai_deadline_at: nil, progress_due_at: nil)

      result = say(human_text)

      expect(result.ticket.id).to eq(ticket.id)
      expect(handoff_items(ticket)).to be_empty
      expect(human_audits(ticket).sole.data).to include("state" => "resolvido", "outcome" => "registrado")
    end
  end

  describe "RN-34: expressões da marca e do idioma (marca errada)" do
    it "texto em inglês na marca pt-BR não dispara" do
      result = say("I want to talk to a human")

      expect(handoff_items(result.ticket)).to be_empty
      expect(human_audits(result.ticket)).to be_empty
      expect(result.ticket.reload.first_pending_seq).to eq(1)
    end

    it "na marca em inglês, o texto em inglês dispara e o em português não" do
      jim.update_columns(locale: "en")
      english = say("I want to talk to a human", brand: "jim", identity: "acc_jim_humano_en")
      portuguese = say(human_text, brand: "jim", identity: "acc_jim_humano_pt")

      expect(handoff_items(english.ticket).sole.payload["reason"]).to eq("pedido_do_cliente")
      expect(handoff_items(portuguese.ticket)).to be_empty
    end

    it "isolamento: o pedido na JIM não toca o atendimento nem o turno da InfinitePay do mesmo identificador" do
      ip_turn = open_turn_for(say("meu repasse não caiu"))

      jim_result = say(human_text, brand: "jim")

      expect(jim_result.ticket.brand_id).to eq(jim.id)
      expect(handoff_items(jim_result.ticket).sole.brand_id).to eq(jim.id)
      expect(ip_turn.reload.status).to eq("eligible")
      expect(handoff_items(ip_turn.ticket)).to be_empty
      expect(AuditEvent.where(event_type: "customer.human_requested").pluck(:brand_id)).to eq([ jim.id ])
    end
  end

  describe "RNF-14: falha de dependência ao acordar o job" do
    it "Redis fora: a mensagem e o pedido ficam gravados e abertos no outbox para a recuperação" do
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "redis fora do ar")

      result = say(human_text)

      expect(result).to be_created
      expect(handoff_items(result.ticket).sole.completed_at).to be_nil
      expect(OutboxEvent.find(result.outbox_event_id).completed_at).to be_nil
      expect(human_audits(result.ticket).sole.data["outcome"]).to eq("handoff_pedido")
    end

    it "o Redis falha só no primeiro despertador: o do pedido ainda é tentado" do
      calls = []
      allow(OutboxJob).to receive(:perform_later) do |id|
        calls << id
        raise RedisClient::CannotConnectError, "redis fora do ar" if calls.size == 1
      end

      result = say(human_text)

      expect(calls).to contain_exactly(result.outbox_event_id, result.handoff_event_id)
    end
  end

  describe "RN-34, RN-46: pedido no instante exato do vencimento do turno" do
    it "no prazo do turno, antes do worker do timeout: o pedido do cliente expira o turno; o timeout descarta" do
      turn = open_turn_for(say("meu repasse não caiu"))
      deadline = turn.deadline_at

      travel_to(deadline)
      allow(DatabaseClock).to receive(:now) { Time.current }
      timeout = Deadlines::TurnTimeout.call(now: Time.current, limit: 10).sole
      say(human_text)

      expect(Deadlines::Expire.call(timeout).status).to eq(:discarded)
      expect(turn.reload.status).to eq("expired")
      expect(handoff_items(turn.ticket).sole.payload).to include("reason" => "pedido_do_cliente", "turn" => turn.turn)
      expect(human_audits(turn.ticket).sole.data["outcome"]).to eq("handoff_pedido")
    end

    it "um instante depois de o timeout pedir o handoff: o pedido do cliente fica handoff_ja_pedido" do
      turn = open_turn_for(say("meu repasse não caiu"))

      travel_to(turn.deadline_at + 0.001.seconds, with_usec: true)
      allow(DatabaseClock).to receive(:now) { Time.current }
      Deadlines::Expire.call(Deadlines::TurnTimeout.call(now: Time.current, limit: 10).sole)
      say(human_text)

      expect(handoff_items(turn.ticket).sole.payload["reason"]).to eq("prazo_do_turno")
      expect(human_audits(turn.ticket).sole.data["outcome"]).to eq("handoff_ja_pedido")
    end
  end

  describe "RN-34: mensagem comum depois do pedido (ordem)" do
    it "não abre turno: o Turns::Open recusa (handoff_pedido) e o Escalate encerra o ciclo" do
      default_queue(infinitepay)
      first = say(human_text)
      ticket = say("é sobre o repasse de ontem").ticket

      expect(handoff_items(ticket).count).to eq(1)
      expect(Turns::Open.call(due_dispatch(ticket).id).status).to eq(:handoff_requested)
      Handoff::Escalate.call(first.handoff_event_id)

      expect(ticket.reload).to have_attributes(state: "aguardando_humano", latest_customer_seq: 2, first_pending_seq: nil,
                                               dispatch_due_at: nil, ai_deadline_at: nil, progress_due_at: nil)
      expect(ticket.ai_turns).to be_empty
    end

    it "mensagem comum depois do Escalate entra no histórico humano sem abrir ciclo" do
      default_queue(infinitepay)
      Handoff::Escalate.call(say(human_text).handoff_event_id)

      ticket = say("alguém aí?").ticket.reload

      expect(ticket).to have_attributes(state: "aguardando_humano", first_pending_seq: nil, dispatch_due_at: nil)
      expect(human_audits(ticket).count).to eq(1)
    end
  end
end
