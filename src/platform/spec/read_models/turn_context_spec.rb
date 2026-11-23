require "rails_helper"

RSpec.describe RecordedConversations, "RN-55, RN-49, RF-55: o card do turno mostra as mensagens que entraram e confere o contexto" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }
  let(:source) { described_class.new }

  around { |example| travel_to(t0) { example.run } }

  def turn_view(turn) = source.find(turn.ticket_id.to_s).turns.find { _1.number == turn.turn }

  # Turno 1 respondido (seq 1 e 2), depois três mensagens agrupadas no turno 2 (seq 3, 4, 5).
  def grouped_turn
    first = ingest("oi")
    turn1 = record_turn_06(first.ticket, context_version: 1)
    record_outbound(turn1, text: "Olá! Como posso ajudar?")
    [ "meu repasse não caiu", "é o de ontem", "R$ 1.200" ].each_with_index do |text, i|
      travel_to(t0 + 2 + i)
      ingest(text)
    end
    record_turn_06(first.ticket, context_version: 5)
  end

  it "turno com 3 mensagens agrupadas: as pendentes separadas do histórico, com context_version" do
    context = turn_view(grouped_turn).context

    expect(context.pending_messages.map { [ _1.seq, _1.text ] })
      .to eq([ [ 3, "meu repasse não caiu" ], [ 4, "é o de ontem" ], [ 5, "R$ 1.200" ] ])
    expect(context.history.map { [ _1.seq, _1.author, _1.text ] })
      .to eq([ [ 1, "customer", "oi" ], [ 2, "bot", "Olá! Como posso ajudar?" ] ])
    expect(context.context_version).to eq(5)
  end

  it "contexto conferido: o digest recalculado bate com o gravado" do
    context = turn_view(grouped_turn).context

    expect(context).to have_attributes(check: :verified, check_label: "Contexto conferido")
    expect(context.recorded_digest).to eq(context.computed_digest)
    expect(context.short_digest).to eq(context.recorded_digest.delete_prefix("sha256:").first(12))
  end

  it "contexto divergente: o context gravado mudou depois do digest" do
    turn = grouped_turn
    turn.update_columns(context: turn.context.merge("pending_messages" => turn.context["pending_messages"].first(2)))

    expect(turn_view(turn).context).to have_attributes(check: :diverged, check_label: "Contexto diverge do gravado")
  end

  it "turno sem digest é anterior ao bloco 06" do
    turn = record_turn_06(ingest("oi").ticket, context_version: nil, digest: nil)

    expect(turn_view(turn).context).to have_attributes(check: :missing, check_label: "Turno anterior ao bloco 06",
                                                       context_version: nil)
  end

  it "turno aberto pelo Turns::Open: o contexto gravado nunca aparece como divergente" do
    turn = open_turn_for(ingest("oi"))

    expect(turn_view(turn).context.check).not_to eq(:diverged)
    expect(turn_view(turn).context.pending_messages.map(&:seq)).to eq([ 1 ])
  end

  it "marca errada: cada atendimento mostra só o contexto do seu turno" do
    create(:brand, :jim)
    mine = record_turn_06(ingest("oi").ticket)
    other = record_turn_06(ingest("mensagem da JIM", brand: "jim", identity: "acc_jim_000021").ticket)

    expect(turn_view(mine).context.pending_messages.map(&:text)).to eq([ "oi" ])
    expect(turn_view(other).context.pending_messages.map(&:text)).to eq([ "mensagem da JIM" ])
  end
end
