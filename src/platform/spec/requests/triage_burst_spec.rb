require "rails_helper"

# Achado D1 da verificação do bloco 11: o worker do message.received rodava ~40 ms depois da 1ª mensagem e
# classificava só ela; a 2ª da rajada (RN-55) nunca contava, e a RN-17 impede corrigir depois. A triagem espera a
# janela de agrupamento: o worker não classifica com a janela aberta, e o Turns::Open tria no fim dela, sob o lock.
RSpec.describe "RF-12, RN-55: triagem de uma rajada dentro da janela" do
  include ActiveJob::TestHelper

  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand: infinitepay, slug: "infinitepay-chat-mock") }
  let!(:config) { triage_setup(infinitepay) }
  let(:t0) { Time.utc(2026, 11, 22, 14, 0, 0) }

  around { |example| travel_to(t0) { example.run } }

  def post_chat(text)
    raw = { message_id: SecureRandom.uuid, account_id: "acc_infinitepay_000021", customer_ref: "cus_ref_000021", text:,
            sent_at: "2026-11-22T14:00:00.000Z" }.to_json
    post "/webhooks/chat/infinitepay-chat-mock", params: raw, headers: {
      "CONTENT_TYPE" => "application/json",
      HelpdeskContracts::Signature::HEADER => HelpdeskContracts::Signature.header(raw, secret: account.secret)
    }
  end

  it "classifica a rajada inteira: 'oi' e, 50 ms depois, 'minha maquininha não liga'" do
    stub_broker
    allow(DatabaseClock).to receive(:now) { Time.current } # o relógio do banco não segue o travel_to
    perform_enqueued_jobs { post_chat("oi") }            # o worker roda logo, como em produção
    travel 0.05.seconds
    perform_enqueued_jobs { post_chat("minha maquininha não liga") }

    ticket = Ticket.sole
    expect(ticket.reload).to have_attributes(state: "novo", category: nil) # janela aberta: a rajada ainda não fechou

    travel 2.seconds # fim da janela de 1,5 s (o travel descarta frações de segundo)
    ids = Deadlines::DispatchDue.call(now: Time.current, limit: 10)
    perform_enqueued_jobs { ids.each { OutboxJob.perform_later(_1) } }

    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "routing.decided").count).to eq(1)
    expect(ticket.reload).to have_attributes(category: "maquininha", priority: "critica", state: "com_ia")
    expect(AuditEvent.where(ticket_id: ticket.id, event_type: "triage.classified").sole.data["seqs"]).to eq([ 1, 2 ])
  end
end
