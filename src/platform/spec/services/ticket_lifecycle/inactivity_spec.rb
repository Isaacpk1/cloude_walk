require "rails_helper"

RSpec.describe "RN-07, ADR-016: inatividade depois da entrega" do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand:, slug: "infinitepay-chat-mock") }
  let(:start) { Time.current.change(usec: 0) }
  let(:inbound) { customer_message }
  let(:ticket) { inbound.ticket }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  def deliver_reply
    ticket.update_columns(state: "com_ia")
    delivery = requested_delivery(ticket)
    stub_channels(status: 200)
    Deliveries::Send.call(delivery_item(delivery).id)
    ticket.reload
  end

  it "RN-07: só começa a espera após a entrega confirmada e encerra na mensagem nova" do
    travel_to(start) do
      deliver_reply
      expect(ticket).to have_attributes(state: "aguardando_cliente", waiting_since: start,
                                       reminder_due_at: start + 24.hours, inactivity_due_at: start + 48.hours)
      ingest("ainda preciso de ajuda")
      expect(ticket.reload).to have_attributes(state: "com_ia", waiting_since: nil, reminder_due_at: nil, inactivity_due_at: nil)
    end
  end

  it "RN-07: falha no canal não inicia o prazo" do
    ticket.update_columns(state: "com_ia")
    delivery = requested_delivery(ticket)
    stub_channels(status: 503)
    Deliveries::Send.call(delivery_item(delivery).id)
    expect(ticket.reload.waiting_since).to be_nil
  end

  it "RN-07: um lembrete no limite de 24 h, sem repetição no worker nem no scheduler" do
    travel_to(start) { deliver_reply }
    travel_to(start + 24.hours) do
      id = Deadlines::CustomerReminder.call(now: Time.current, limit: 10).sole
      2.times { OutboxJob.perform_now(id) }
      expect(Deadlines::CustomerReminder.call(now: Time.current, limit: 10)).to be_empty
      expect(Delivery.where(ticket_id: ticket.id, kind: "reminder").count).to eq(1)
      expect(ticket.reload.state).to eq("aguardando_cliente")
    end
  end

  it "RN-07: lembrete atrasado depois de 48 h é descartado, e a resolução ocorre uma vez" do
    travel_to(start) { deliver_reply }
    travel_to(start + 24.hours) { @reminder = Deadlines::CustomerReminder.call(now: Time.current, limit: 10).sole }
    travel_to(start + 48.hours) do
      OutboxJob.perform_now(@reminder)
      id = Deadlines::CustomerInactivity.call(now: Time.current, limit: 10).sole
      2.times { OutboxJob.perform_now(id) }
      expect(ticket.reload).to have_attributes(state: "resolvido", resolution_reason: "sem_resposta_do_cliente")
      expect(Delivery.where(ticket_id: ticket.id, kind: "reminder")).to be_empty
      expect(TicketSummary.where(ticket_id: ticket.id).count).to eq(1)
    end
  end

  it "RN-07: nova mensagem torna a ação antiga obsoleta" do
    travel_to(start) { deliver_reply }
    travel_to(start + 48.hours) do
      id = Deadlines::CustomerInactivity.call(now: Time.current, limit: 10).sole
      ingest("estou aqui")
      OutboxJob.perform_now(id)
      expect(ticket.reload.state).to eq("com_ia")
      expect(OutboxEvent.find(id).last_error).to eq("ciclo_mudou")
    end
  end

  it "RN-09: fecha estritamente depois da janela de 72 h" do
    now = Time.current
    ticket.with_lock do
      TicketLifecycle::Resolve.call(ticket:, source: "agent", reason: "confirmado_pelo_cliente", now:, trace_id: SecureRandom.hex(16))
    end
    travel_to(now + 72.hours, with_usec: true) do
      expect(Deadlines::TicketClose.call(now: Time.current, limit: 10)).to be_empty
    end
    travel_to(now + 72.hours + 0.001.seconds, with_usec: true) do
      id = Deadlines::TicketClose.call(now: Time.current, limit: 10).sole
      OutboxJob.perform_now(id)
      expect(ticket.reload.state).to eq("fechado")
    end
  end

  it "RF-48: o analista continua podendo anotar e resolver depois de uma resposta entregue" do
    setup = distribution_setup(brand)
    analyst = analyst_in(setup[:team])
    assigned = case_with(analyst, brand:, queue: setup[:queue], identity: "acc_human")
    reply = Human::Reply.call(ticket_id: assigned.id, brand_id: brand.id, user: analyst, text: "Verifiquei aqui.")
    stub_channels(status: 200)
    Deliveries::Send.call(reply.delivery_event_id)

    expect(Human::Note.call(ticket_id: assigned.id, brand_id: brand.id, user: analyst, text: "Nota interna").status).not_to eq(:rejected)
    result = Human::Resolve.call(ticket_id: assigned.id, brand_id: brand.id, user: analyst, reason: "problema_resolvido")
    expect(result.status).to eq(:resolved)
    expect(analyst.reload.active_count).to eq(0)
  end
end
