require "rails_helper"

# ROADMAP 05: o painel lido a partir do que o AgentActions::Apply e o Deliveries::Send gravam de verdade,
# com o provedor simulado por WebMock (sem os atalhos de spec/support/delivery_records.rb). O Apply usa o
# relógio do banco: aqui não há travel_to antes da aplicação.
RSpec.describe "ROADMAP 05, RF-06: entrega no painel com a aplicação e o envio reais", type: :request do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }

  def applied_delivery
    raw = { "message_id" => "chat_msg_000123", "account_id" => "acc_infinitepay_000021", "customer_ref" => "cus_ref_000021",
            "text" => "meu repasse não caiu", "sent_at" => Time.current.utc.iso8601(3) }
    received = Ingestion::Receive.call(normalized_message(text: "meu repasse não caiu", external_id: "chat_msg_000123"),
                                       provider_payload: raw)
    turn = open_turn_for(received)
    expect(AgentActions::Apply.call(agent_action_for(turn), traceparent: AgentActionHelpers::TRACEPARENT).status).to eq(:applied)
    Delivery.find_by!(ticket_id: turn.ticket_id)
  end

  # O texto da mensagem de saída: selo do status e o bloco da entrega.
  def delivery_html(ticket_id)
    get conversation_path(ticket_id)
    Nokogiri::HTML(response.body).at_css(".delivery").parent.text.squish
  end

  def panel_time(time) = ApplicationController.helpers.panel_time(time)

  it "503 e depois 200: mostra a nova tentativa agendada enquanto espera e a confirmação depois" do
    delivery = applied_delivery
    item = OutboxEvent.find_by!(dedup_key: "delivery:#{delivery.delivery_id}")
    stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT)
      .to_return(channel_response(status: 503)).then
      .to_return(channel_response(status: 200, message_id: "chatmsg_ok"))

    retry_at = Deliveries::Send.call(item.id, jitter: -> { 0.0 }).next_attempt_at
    expect(delivery.reload).to have_attributes(status: "sending", lease_until: nil)

    waiting = delivery_html(delivery.ticket_id)
    expect(waiting).to include("Enviando", "tentativa 1", "nova tentativa às #{panel_time(retry_at)}", "http 503")

    travel_to(retry_at + 1) { expect(Deliveries::Send.call(item.id, jitter: -> { 0.0 }).status).to eq(:delivered) }

    done = delivery_html(delivery.ticket_id)
    expect(done).to include("entregue às", "chatmsg_ok", "tentativa 2")
    expect(done).not_to include("nova tentativa")
  end

  it "durante a tentativa em curso (reserva vigente) não mostra a retentativa anterior" do
    delivery = applied_delivery
    item = OutboxEvent.find_by!(dedup_key: "delivery:#{delivery.delivery_id}")
    stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return(channel_response(status: 503))
    retry_at = Deliveries::Send.call(item.id, jitter: -> { 0.0 }).next_attempt_at

    travel_to(retry_at + 1) do
      # A 2ª tentativa começou (sending, attempts 2, reserva vigente) e ainda não voltou.
      delivery.update_columns(attempts: 2, lease_until: Time.current + Deliveries::Policy::LEASE)
      AuditEvent.create!(brand_id: delivery.brand_id, ticket_id: delivery.ticket_id, actor_type: "system",
                         event_type: "delivery.sending", trace_id: delivery.trace_id,
                         data: { delivery_id: delivery.delivery_id, seq: delivery.seq, attempt: 2 })

      expect(delivery_html(delivery.ticket_id)).to include("Enviando", "tentativa 2")
      expect(delivery_html(delivery.ticket_id)).not_to include("nova tentativa")
    end
  end
end
