require "rails_helper"

# Bloco 15, RF-47: o analista vê, no contexto do atendimento, os atendimentos anteriores do mesmo cliente (de qualquer
# canal), só da mesma marca (RN-52).
RSpec.describe "RF-47: histórico dos atendimentos anteriores do cliente", :anonymous do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:ip) { distribution_setup(infinitepay) }
  let!(:jm) { distribution_setup(jim) }
  let!(:ana) { analyst_in(ip[:team], name: "Ana Souza", email: "ana@ip.test") }
  let!(:ticket) { case_with(ana, brand: infinitepay, queue: ip[:queue], identity: "acc_1") }
  let(:doc) { Nokogiri::HTML(response.body) }

  before { sign_in(ana) }

  def previous_for(customer, channel:, state:)
    Ticket.create!(brand: customer.brand, customer:, channel:, state:)
  end

  it "lista os atendimentos anteriores do mesmo cliente, com canal e estado, do mais novo ao mais antigo" do
    older = previous_for(ticket.customer, channel: "whatsapp", state: "resolvido")
    newer = previous_for(ticket.customer, channel: "email", state: "resolvido")

    get conversation_path(ticket.id)

    rows = doc.css(".customer-history li")
    expect(rows.map { _1["data-ticket-id"] }).to eq([ newer.id.to_s, older.id.to_s ])
    expect(rows.first.text).to include("email", "resolvido")
    expect(rows.last.text).to include("whatsapp")
  end

  it "não lista o próprio atendimento nem o de outro cliente" do
    other = create(:customer, brand: infinitepay)
    previous_for(other, channel: "chat", state: "resolvido")

    get conversation_path(ticket.id)

    expect(doc.css(".customer-history li")).to be_empty
    expect(response.body).to include("Primeiro atendimento deste cliente")
  end

  it "RF-52: mostra o resumo persistido do atendimento anterior" do
    previous = previous_for(ticket.customer, channel: "email", state: "resolvido")
    TicketSummary.create!(brand: infinitepay, ticket: previous, assignment_version: 0, resolved_at: Time.current,
                          body: "Problema de repasse resolvido.", created_at: Time.current)
    get conversation_path(ticket.id)
    expect(doc.css(".customer-history").text).to include("Problema de repasse resolvido.")
  end

  it "RN-52: não mistura atendimentos de outra marca com o mesmo identificador" do
    foreign = create(:customer, brand: jim)
    previous_for(foreign, channel: "chat", state: "resolvido")

    get conversation_path(ticket.id)

    expect(doc.css(".customer-history li")).to be_empty
  end
end
