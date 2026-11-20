require "rails_helper"

# Bloco 03, ponta a ponta sem atalhos: a ingestão grava a janela (RN-55), o scheduler real
# (Deadlines::DispatchDue) registra a abertura no outbox quando ela vence (ADR-016), o worker
# (OutboxJob) abre o turno e o publicador assina e envia ao broker (stub de spec/support/broker.rb).
RSpec.describe "RN-55, ADR-016: rajada no chat vira um turno só, aberto pelo scheduler" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let(:t0) { Time.zone.parse("2026-11-19 13:40:00") }

  def post_chat(text)
    raw = { message_id: SecureRandom.uuid, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021",
            text:, sent_at: "2026-11-19T13:40:00.000Z" }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json", "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
    expect(response).to have_http_status(:accepted)
  end

  def scheduler_tick = perform_enqueued_jobs { Deadlines::DispatchDue.call(now: Time.current, limit: 100) }

  it "RN-55: mensagens aos 0 s e 1 s saem juntas aos 2,5 s; antes disso, nada vai ao broker" do
    stub_broker

    travel_to(t0) { perform_enqueued_jobs { post_chat("meu repasse não caiu") } }
    travel_to(t0 + 1.second) { perform_enqueued_jobs { post_chat("é o de ontem, R$ 1.200") } }

    travel_to(t0 + 2.4.seconds, with_usec: true) { scheduler_tick }
    expect(broker_requests).to be_empty
    expect(AiTurn.count).to eq(0)

    travel_to(t0 + 2.5.seconds, with_usec: true) { scheduler_tick }
    turn = AiTurn.sole
    expect(turn.context_until_seq).to eq(2)
    event = JSON.parse(broker_requests.sole.body)
    expect(event.dig("context", "pending_messages").map { _1["seq"] }).to eq([ 1, 2 ])
    expect(Ticket.sole.dispatch_due_at).to be_nil

    travel_to(t0 + 3.seconds, with_usec: true) { scheduler_tick }
    expect(AiTurn.count).to eq(1)
    expect(broker_requests.size).to eq(1)
  end

  it "RN-55: rajada contínua sai no teto de 4 s desde a primeira mensagem" do
    stub_broker

    [ 0, 1, 2, 3 ].each { |s| travel_to(t0 + s.seconds, with_usec: true) { perform_enqueued_jobs { post_chat("msg #{s}") } } }

    travel_to(t0 + 3.9.seconds, with_usec: true) { scheduler_tick }
    expect(AiTurn.count).to eq(0)

    travel_to(t0 + 4.seconds, with_usec: true) { scheduler_tick }
    expect(AiTurn.sole.context_until_seq).to eq(4)
    expect(broker_requests.size).to eq(1)
  end
end
