require "rails_helper"

# 07, seção 3.1, passo 2: o worker do aviso da ingestão faz a triagem do caso novo, fora da requisição (P1).
RSpec.describe Triage::OnMessage, "RF-12, RF-24: triagem no worker do message.received" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:config) { triage_setup(infinitepay) }
  let(:start) { Time.zone.parse("2026-11-22T12:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def audits(ticket, type) = AuditEvent.where(ticket_id: ticket.id, event_type: type).order(:id)

  it "trava o caso, faz a triagem e conclui o item na mesma transação, com o trace_id da mensagem" do
    received = ingest("meu repasse não caiu", trace_id: "f" * 32)
    item = received_item(received)

    result = described_class.call(item.id)

    expect(result.status).to eq(:triaged_to_ai)
    expect(received.ticket.reload).to have_attributes(state: "com_ia", assignee_id: config[:bot].id, category: "repasses",
                                                      queue_id: config[:default].id)
    expect(item.reload).to have_attributes(completed_at: start, lease_until: nil)
    expect(audits(received.ticket, "triage.classified").sole.trace_id).to eq("f" * 32)
  end

  it "repetição: o mesmo aviso duas vezes faz uma triagem só" do
    item = received_item(ingest("meu repasse não caiu"))
    described_class.call(item.id)

    result = described_class.call(item.id)

    expect(result.status).to eq(:already_done)
    expect(AuditEvent.where(event_type: "triage.classified").count).to eq(1)
    expect(AuditEvent.where(event_type: "routing.decided").count).to eq(1)
  end

  it "item reoferecido depois de a triagem já ter coberto a mensagem: conclui e audita ja_triado" do
    first = ingest("meu repasse não caiu")
    second = ingest("é o de ontem")
    described_class.call(received_item(first).id)

    result = described_class.call(received_item(second).id)

    expect(result).to have_attributes(status: :skipped, reason: "ja_triado")
    expect(received_item(second).completed_at).to eq(start)
    expect(AuditEvent.where(event_type: "routing.decided").count).to eq(1)
  end

  it "RN-17: mensagem de um caso já triado só conclui o item, sem re-rotear" do
    first = ingest("meu repasse não caiu")
    described_class.call(received_item(first).id)
    later = ingest("é o de ontem")

    result = described_class.call(received_item(later).id)

    expect(result.status).to eq(:not_applicable)
    expect(received_item(later).completed_at).to eq(start)
    expect(AuditEvent.where(event_type: %w[routing.decided triage.skipped]).count).to eq(1)
  end

  it "falha do avaliador: o erro sobe, o item fica aberto para a recuperação e o caso continua novo" do
    received = ingest("meu repasse não caiu")
    allow(Routing::Evaluate).to receive(:call).and_raise(ActiveRecord::ConnectionFailed)

    expect { described_class.call(received_item(received).id) }.to raise_error(ActiveRecord::ConnectionFailed)

    expect(received_item(received).completed_at).to be_nil
    expect(received.ticket.reload.state).to eq("novo")
  end

  it "item inexistente não faz nada; item e atendimento de marcas diferentes o banco já recusa (invariante 6)" do
    jim = create(:brand, :jim)
    item = received_item(ingest("meu repasse não caiu"))

    expect(described_class.call(-1).status).to eq(:not_found)
    expect { item.update_columns(brand_id: jim.id) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
