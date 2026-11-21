require "rails_helper"

RSpec.describe RecordedConversations, "RN-55, RF-55: a conversa mostra a fase de agrupamento" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:source) { described_class.new }

  around { |example| travel_to(t0) { example.run } }

  def grouping(ticket) = source.find(ticket.id.to_s).grouping

  it "com a janela aberta: as mensagens aguardando, a janela do canal, o fim previsto e o teto; vale a janela" do
    first = ingest("meu repasse não caiu")
    travel_to(t0 + 1.second)
    ingest("é o de ontem")

    phase = grouping(first.ticket)

    expect(phase).to have_attributes(pending_seqs: [ 1, 2 ], channel: "chat", window_ms: 1_500,
                                     dispatch_due_at: t0 + 2.5.seconds, ceiling_at: t0 + 4.seconds,
                                     prevails: :window, overdue: false)
    expect(phase.summary).to include("janela de 1500 ms", "vale a janela")
  end

  it "RN-55, tempo no limite: o teto de 4 s desde a primeira pendente prevalece sobre a janela" do
    first = ingest("meu repasse não caiu")
    travel_to(t0 + 1.second)
    ingest("é o de ontem")
    travel_to(t0 + 3.seconds)
    ingest("R$ 1.200")

    phase = grouping(first.ticket)

    expect(phase).to have_attributes(pending_seqs: [ 1, 2, 3 ], dispatch_due_at: t0 + 4.seconds,
                                     ceiling_at: t0 + 4.seconds, prevails: :ceiling)
    expect(phase.summary).to include("vale o teto")
  end

  it "um instante depois do fim previsto, a fase continua até o scheduler abrir o turno" do
    first = ingest("oi")
    travel_to(t0 + 1.501.seconds, with_usec: true)

    expect(grouping(first.ticket)).to have_attributes(overdue: true)
    expect(grouping(first.ticket).summary).to include("aguardando o scheduler")
  end

  it "RN-55: e-mail tem janela 0 e sai na próxima volta do scheduler" do
    received = ingest_on("email", "Assunto: repasse")

    phase = grouping(received.ticket)

    expect(phase).to have_attributes(channel: "email", window_ms: 0, prevails: :none, dispatch_due_at: t0)
    expect(phase.summary).to include("sem janela: sai na próxima volta do scheduler")
  end

  it "some depois que o turno abre para a última mensagem e volta com mensagem nova" do
    first = ingest("oi")
    travel_to(t0 + 1.5.seconds)
    record_turn_06(first.ticket)

    expect(grouping(first.ticket)).to be_nil

    travel_to(t0 + 2.seconds)
    ingest("é o de ontem")

    expect(grouping(first.ticket)).to have_attributes(pending_seqs: [ 1, 2 ])
  end

  it "caso fora da IA não tem fase de agrupamento" do
    first = ingest("oi")
    first.ticket.update_columns(state: "com_analista", assignee_id: create(:user).id)

    expect(grouping(first.ticket)).to be_nil
  end

  it "marca errada: só as mensagens da marca do atendimento entram na fase" do
    create(:brand, :jim)
    mine = ingest("oi")
    ingest("mensagem da JIM", brand: "jim", identity: "acc_jim_000021")

    expect(grouping(mine.ticket).pending_seqs).to eq([ 1 ])
    expect(source.find(mine.ticket.id.to_s).messages.map(&:body)).to eq([ "oi" ])
  end
end
