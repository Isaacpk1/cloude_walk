require "rails_helper"

# Tempo real do painel (ROADMAP 10; RNF-06: entrada na fila p95 ≤ 2 s; 07, seção 3.2 "Broadcast por ActionCable").
# O AuditEvent de ticket.escalated e handoff.summary_* pede a recarga da fila (stream geral e da marca) e da conversa,
# só depois do commit e nunca num rollback (invariante 2: nada externo com a transação aberta). Fora da transação de
# teste, com o Postgres de verdade, para o commit ser o de produção.
RSpec.describe AuditEvent, "RNF-06, invariante 2: broadcast do painel depois do commit", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let!(:ticket) { ingest("meu repasse não caiu").ticket }
  let(:pubsub) { ActionCable.server.pubsub }

  before { pubsub.clear }

  def name_for(*streamables) = Turbo::StreamsChannel.send(:stream_name_from, streamables)
  def broadcasts(*streamables) = pubsub.broadcasts(name_for(*streamables))
  def general = broadcasts(:human_queue)
  def brand_stream(brand = infinitepay) = broadcasts(:human_queue, brand)
  def conversation = broadcasts(*ConversationView.stream_for(infinitepay.slug, ticket.id))

  def audit!(event_type = "ticket.escalated", brand: infinitepay)
    AuditEvent.create!(brand:, ticket_id: brand == infinitepay ? ticket.id : nil, actor_type: "system", event_type:,
                       trace_id: "e" * 32, data: { "from_assignment_version" => 0 })
  end

  it "nada dentro da transação; um pedido de recarga depois do commit, no geral, na marca e na conversa" do
    inside = nil
    ActiveRecord::Base.transaction do
      audit!
      inside = [ general.size, brand_stream.size, conversation.size ]
    end

    expect(inside).to eq([ 0, 0, 0 ])
    expect([ general.size, brand_stream.size, conversation.size ]).to eq([ 1, 1, 1 ])
    expect(JSON.parse(general.sole)).to eq(%(<turbo-stream action="refresh"></turbo-stream>))
  end

  it "rollback: nenhum broadcast" do
    ActiveRecord::Base.transaction do
      audit!
      raise ActiveRecord::Rollback
    end

    expect([ general, brand_stream, conversation ]).to all(be_empty)
  end

  it "erro depois da auditoria desfaz a transação e não avisa ninguém" do
    expect do
      ActiveRecord::Base.transaction do
        audit!("handoff.summary_available")
        raise "falhou depois"
      end
    end.to raise_error("falhou depois")

    expect(general).to be_empty
  end

  it "handoff.summary_available e _missing também avisam; outras auditorias não" do
    audit!("handoff.summary_available")
    audit!("handoff.summary_missing")
    audit!("delivery.requested")
    audit!("handoff.requested")

    expect(brand_stream.size).to eq(2)
  end

  it "RN-28, RNF-06: a triagem que manda o caso à fila humana avisa o painel; a atribuição à IA não" do
    AuditEvent.create!(brand: infinitepay, ticket_id: ticket.id, actor_type: "system", event_type: "ticket.assigned",
                       trace_id: "e" * 32, data: { "to" => "ia" })
    expect(brand_stream).to be_empty

    AuditEvent.create!(brand: infinitepay, ticket_id: ticket.id, actor_type: "system", event_type: "ticket.assigned",
                       trace_id: "e" * 32, data: { "to" => "fila_humana" })
    expect([ general.size, brand_stream.size, conversation.size ]).to eq([ 1, 1, 1 ])
  end

  it "marca errada: o stream de outra marca não recebe o aviso" do
    audit!

    expect(brand_stream(jim)).to be_empty
  end

  it "o stream não leva dado do caso, só o pedido de recarga (o isolamento fica na página que recarrega)" do
    audit!

    expect(brand_stream.sole).not_to include("quero falar", ticket.id.to_s)
  end

  it "falha do ActionCable depois do commit não levanta nem desfaz: só o log" do
    allow(Turbo::StreamsChannel).to receive(:broadcast_refresh_to).and_raise(IOError, "cable fora do ar")
    allow(Rails.logger).to receive(:warn)

    expect { audit! }.not_to raise_error

    expect(AuditEvent.where(event_type: "ticket.escalated").count).to eq(1)
    expect(Rails.logger).to have_received(:warn).with(include("panel.broadcast_failed", "e" * 32))
  end

  it "ponta a ponta: o Handoff::Escalate real avisa a fila da marca uma vez, depois do commit" do
    default_queue_for(infinitepay)
    id = ActiveRecord::Base.transaction do
      locked = Ticket.lock.find_by!(id: ticket.id, brand_id: infinitepay.id)
      Handoff::Request.call(ticket: locked, reason: "pedido_do_cliente", source: "ingestion", trace_id: "f" * 32)
    end
    expect(brand_stream).to be_empty

    Handoff::Escalate.call(id)

    expect(brand_stream.size).to be >= 1
    expect(general.size).to eq(brand_stream.size)
  end
end
