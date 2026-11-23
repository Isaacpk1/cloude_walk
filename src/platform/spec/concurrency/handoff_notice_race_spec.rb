require "rails_helper"

# Bloco 10: o aviso de transferência contra a última resposta da IA, com o Postgres de verdade, fora da transação
# de teste (AGENTS.md, item 3; 07, seção 3.2 "Transferência e ordem de entrega"; RN-38, RN-42, RF-43).
#
# O pedido de handoff (Handoff::Request, que cancela as saídas pending da IA no commit, RN-38) e o Deliveries::Send
# travam o atendimento. Ou o pedido vence e a resposta pending é cancelada antes de sair (o cliente só recebe o aviso),
# ou o Send vence e a resposta já está `sending` quando o pedido e o Escalate rodam: o aviso espera o resultado dela.
# Nunca o aviso antes de uma resposta da IA que acabou entregue.
RSpec.describe "RN-38, RN-42: aviso de transferência × envio da última resposta da IA", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:queue) { default_queue(infinitepay) }
  let(:reply_text) { "Seu repasse cai hoje até as 18h." }
  let(:notice_text) { Handoff::Policy::DEFAULT.transfer_notice_text("pt-BR") }

  # O provedor do chat: guarda o texto de cada chamada e, com `gate`, segura a primeira resposta até o teste soltar.
  def stub_provider(gate: nil)
    @texts = Queue.new
    @in_call = Queue.new
    first = true
    stub_request(:post, DeliveryHelpers::CHANNELS_ENDPOINT).to_return do |request|
      @texts << JSON.parse(request.body)["text"]
      if gate && first
        first = false
        @in_call << true
        gate.pop(timeout: 10) or raise "o teste não soltou a chamada"
      end
      channel_response(status: 200, message_id: "chat_out_#{SecureRandom.hex(4)}")
    end
  end

  def provider_texts
    texts = []
    texts << @texts.pop until @texts.empty?
    texts
  end

  def notice(ticket) = Delivery.find_by!(ticket_id: ticket.id, kind: "handoff_notice")

  # Roda o envio de cada saída aberta, na ordem do seq, depois da espera de ordem (ORDER_RECHECK).
  def drain(ticket)
    3.times do
      travel(Deliveries::Policy::ORDER_RECHECK + 1.second)
      Delivery.open.where(ticket_id: ticket.id).order(:seq).each { Deliveries::Send.call(delivery_item(_1).id) }
    end
  end

  def scenario
    ticket = customer_message.ticket
    [ ticket, requested_delivery(ticket, text: reply_text) ]
  end

  def ask_human(ticket) = request_handoff(ticket.reload, reason: "pedido_do_cliente", source: "ingestion")

  it "corrida livre (Escalate e Send ao mesmo tempo): o aviso nunca sai antes de uma resposta entregue" do
    stub_provider
    ticket, reply = scenario

    results = run_concurrently(threads: 2) { |i| i.zero? ? ask_human(ticket) : Deliveries::Send.call(delivery_item(reply).id) }
    expect(results).to all(satisfy { !_1.is_a?(Exception) })
    Handoff::Escalate.call(handoff_items(ticket).sole.id)
    drain(ticket)

    texts = provider_texts
    if reply.reload.status == "delivered"
      expect(texts).to eq([ reply_text, notice_text ])
    else
      expect(reply.status).to eq("cancelled")
      expect(texts).to eq([ notice_text ])
    end
    expect(notice(ticket).reload.status).to eq("delivered")
  end

  it "pedido primeiro: a resposta pending é cancelada no pedido, antes de sair, e o cliente só recebe o aviso" do
    stub_provider
    ticket, reply = scenario

    handoff_id = ask_human(ticket)
    expect(reply.reload.status).to eq("cancelled")
    expect(Handoff::Escalate.call(handoff_id).status).to eq(:escalated)
    expect(Deliveries::Send.call(delivery_item(reply).id).status).to eq(:skipped)
    drain(ticket)

    expect(reply.reload.status).to eq("cancelled")
    expect(provider_texts).to eq([ notice_text ])
    expect(notice(ticket).reload.status).to eq("delivered")
  end

  it "Send primeiro: a resposta já está sending quando o pedido e o Escalate rodam, e o aviso espera o resultado dela" do
    gate = Queue.new
    stub_provider(gate:)
    ticket, reply = scenario

    sender = Thread.new { ActiveRecord::Base.connection_pool.with_connection { Deliveries::Send.call(delivery_item(reply).id) } }
    @in_call.pop(timeout: 10) or raise "a chamada da resposta não começou" # fora de transação

    handoff_id = ask_human(ticket)
    expect(reply.reload.status).to eq("sending") # o pedido não cancela uma saída que já começou
    expect(Handoff::Escalate.call(handoff_id).status).to eq(:escalated)
    expect(reply.reload.status).to eq("sending")
    expect(Deliveries::Send.call(delivery_item(notice(ticket)).id).status).to eq(:waiting_previous)

    gate << true
    expect(sender.value.status).to eq(:delivered)
    # A resposta encerrada acorda a próxima saída aberta: o aviso.
    expect(Deliveries::Send.call(delivery_item(notice(ticket)).id).status).to eq(:delivered)

    expect(provider_texts).to eq([ reply_text, notice_text ])
    expect(notice(ticket).seq).to be > reply.seq
  end
end
