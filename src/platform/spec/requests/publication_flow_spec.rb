require "rails_helper"

# ROADMAP 03, "pronto quando": a mensagem do simulador gera um evento válido no tópico de entrada,
# visível pela correlação. O turno abre pela ação "turn.dispatch" do scheduler no fim da janela
# (RN-55, ADR-016); aqui o helper due_dispatch faz o papel do scheduler. Aqui o broker é o stub de spec/support/broker.rb, que confere assinatura e
# contrato como o broker real; a publicação no Kafka é testada em src/broker.
RSpec.describe "RF-29, RF-30, RF-56: do webhook do canal ao webhook assinado para o broker" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }

  def post_chat(text, message_id: SecureRandom.uuid)
    raw = { message_id:, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021", text:,
            sent_at: "2026-11-17T13:40:00.000Z" }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json", "traceparent" => "00-#{trace_id}-00f067aa0ba902b7-01",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
  end

  # O fim da janela vira a ação do scheduler, processada pelo worker (OutboxJob) como em produção.
  def window_ends
    perform_enqueued_jobs { OutboxJob.perform_later(due_dispatch(Ticket.sole).id) }
  end

  it "RN-55: a mensagem não abre turno sozinha; no fim da janela vira um evento assinado, no contrato e com o mesmo trace_id" do
    stub_broker

    perform_enqueued_jobs { post_chat("meu repasse não caiu") }
    expect(broker_requests).to be_empty
    window_ends

    expect(response).to have_http_status(:accepted)
    request = broker_requests.sole
    expect { verify_broker_request!(request) }.not_to raise_error
    event = JSON.parse(request.body)
    ticket = Ticket.sole
    expect(event).to include("conversation_id" => "tkt_#{ticket.id}", "brand" => "infinitepay", "turn" => 1)
    expect(request.headers["Traceparent"]).to start_with("00-#{trace_id}-")
    expect(ticket.audit_events.pluck(:event_type)).to eq(%w[ticket.created message.received triage.classified
                                                             routing.decided ticket.assigned ai_turn.opened
                                                             agent_event.published])
    expect(ticket.audit_events.pluck(:trace_id).uniq).to eq([ trace_id ])
  end

  it "reentrega do mesmo webhook do canal não gera segundo evento (RNF-15)" do
    stub_broker

    perform_enqueued_jobs do
      post_chat("oi", message_id: "chat_msg_1")
      post_chat("oi", message_id: "chat_msg_1")
    end
    window_ends

    expect(response).to have_http_status(:ok)
    expect(broker_requests.size).to eq(1)
  end
end
