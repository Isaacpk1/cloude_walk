require "rails_helper"

# Bloco 10: entrega do aviso de transferência quando a confirmação da última resposta da IA se perde (07, seção 3.2;
# ADR-021; RN-38, RN-42, RF-06 + RF-39 + RF-43 "entrega no handoff"). O aviso só sai depois de um resultado
# definitivo da resposta: pela retentativa com o mesmo delivery_id ou, esgotadas as tentativas, pela conciliação.
RSpec.describe "RN-38, RN-42: aviso de transferência depois de uma confirmação perdida" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:queue) { default_queue(infinitepay) }
  let(:jitter) { -> { 0.0 } }
  let(:notice_text) { Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR") }

  def send_delivery(delivery) = Deliveries::Send.call(delivery_item(delivery).id, jitter:)
  def notice(ticket) = Delivery.find_by!(ticket_id: ticket.id, kind: "handoff_notice")
  def texts = channel_requests.map { JSON.parse(_1.body)["text"] }

  it "leitura esgotada na resposta: o aviso espera, a retentativa confirma a resposta (replay) e só então o aviso sai" do
    ticket = customer_message.ticket
    reply = requested_delivery(ticket)
    stub_channels({ timeout: true }, { status: 200, message_id: "chat_out_reply", replayed: true },
                  { status: 200, message_id: "chat_out_notice" })

    retry_at = send_delivery(reply).next_attempt_at # a mensagem pode ter chegado: sending, resultado incerto
    Handoff::Escalate.call(request_handoff(ticket, reason: "pedido_do_cliente", source: "ingestion"))

    expect(reply.reload.status).to eq("sending")
    expect(send_delivery(notice(ticket)).status).to eq(:waiting_previous)
    expect(texts).to eq([ "Seu repasse cai hoje até as 18h." ])

    travel_to(retry_at + 1.second) do
      expect(send_delivery(reply).status).to eq(:delivered)
      expect(send_delivery(notice(ticket)).status).to eq(:delivered)
    end

    # O mesmo delivery_id nas duas tentativas da resposta: o provedor deduplica, o cliente vê uma resposta só.
    expect(channel_requests.first(2).map { _1.headers["Idempotency-Key"] }.uniq).to eq([ reply.delivery_id ])
    expect(texts.last).to eq(notice_text)
    expect(notice(ticket).reload).to have_attributes(status: "delivered", provider_message_id: "chat_out_notice")
  end

  it "tentativas esgotadas com resultado incerto (reconciliation_needed): o aviso fica retido até a conciliação" do
    ticket = customer_message.ticket
    reply = requested_delivery(ticket)
    stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_raise(Net::ReadTimeout)

    statuses = []
    Deliveries::Policy::MAX_ATTEMPTS.times do |i|
      result = send_delivery(reply)
      statuses << result.status
      # O cliente pede humano depois da 1ª tentativa incerta: a resposta já está sending.
      Handoff::Escalate.call(request_handoff(ticket, reason: "pedido_do_cliente", source: "ingestion")) if i.zero?
      break unless result.next_attempt_at

      travel_to(result.next_attempt_at, with_usec: true)
    end

    expect(statuses.last).to eq(:reconciliation_needed)
    expect(reply.reload).to have_attributes(status: "sending", lease_until: nil)
    expect(send_delivery(notice(ticket)).status).to eq(:waiting_previous)
    expect(ticket.reload.state).to eq("aguardando_humano") # a fila humana segue disponível durante a espera

    # Conciliação (painel do bloco 09; ação ainda sem serviço): o analista confirma que a resposta chegou.
    WebMock.reset!
    stub_channels({ status: 200, message_id: "chat_out_notice" })
    reply.update!(status: "delivered", provider_message_id: "chat_out_reconciled", delivered_at: Time.current, last_error: nil)
    travel_to(Time.current + Deliveries::Policy::ORDER_RECHECK + 1.second) do
      expect(send_delivery(notice(ticket)).status).to eq(:delivered)
    end
    expect(texts).to eq([ notice_text ])
  end
end
