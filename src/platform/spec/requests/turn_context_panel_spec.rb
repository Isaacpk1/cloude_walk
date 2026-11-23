require "rails_helper"

RSpec.describe "RN-55, RN-49, RF-55, RF-56: o painel mostra o agrupamento e o contexto de cada turno" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  around { |example| travel_to(t0) { example.run } }

  def page_for(ticket)
    get conversation_path(ticket.id)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def grouping_section(body) = body[/<section class="card grouping".*?<\/section>/m]

  describe "fase de agrupamento" do
    it "com a janela aberta: mensagens aguardando, janela, horário previsto e teto" do
      first = ingest("meu repasse não caiu")
      travel_to(t0 + 1.second)
      ingest("é o de ontem")

      section = grouping_section(page_for(first.ticket))

      expect(section).to include("Agrupando mensagens", "seq 1, 2", "janela de 1500 ms no chat", "vale a janela",
                                 "18/11/2026 18:00:02.500", "18/11/2026 18:00:04.000")
    end

    it "com o teto prevalecendo" do
      first = ingest("meu repasse não caiu")
      travel_to(t0 + 1.second)
      ingest("é o de ontem")
      travel_to(t0 + 3.seconds)
      ingest("R$ 1.200")

      expect(grouping_section(page_for(first.ticket))).to include("seq 1, 2, 3", "vale o teto")
    end

    it "e-mail: sem janela" do
      received = ingest_on("email", "Assunto: repasse")

      expect(grouping_section(page_for(received.ticket))).to include("sem janela: sai na próxima volta do scheduler")
    end

    it "some depois que o turno abre" do
      first = ingest("oi")
      travel_to(t0 + 1.5.seconds)
      record_turn_06(first.ticket)

      body = page_for(first.ticket)
      expect(body).not_to include("Agrupando mensagens")
      expect(grouping_section(body)).to be_nil
    end
  end

  describe "mensagens de cada turno e conferência do contexto" do
    def grouped_turn(last_text: "R$ 1.200")
      first = ingest("oi")
      turn1 = record_turn_06(first.ticket, context_version: 1)
      record_outbound(turn1, text: "Olá! Como posso ajudar?")
      [ "meu repasse não caiu", "é o de ontem", last_text ].each_with_index do |text, i|
        travel_to(t0 + 2 + i)
        ingest(text)
      end
      record_turn_06(first.ticket, context_version: 5)
    end

    def turn_card(body, number) = body[/<li class="turn turn--\w+" id="turn-#{number}">.*?<\/li>\s*<!-- \/turn -->/m]

    it "turno com 3 mensagens agrupadas, histórico separado, context_version e contexto conferido" do
      turn = grouped_turn
      card = turn_card(page_for(turn.ticket), 2)

      pending = card[/Mensagens que entraram no turno.*?<\/ol>/m]
      history = card[/Histórico enviado.*?<\/ol>/m]
      expect(pending).to include("seq 3", "meu repasse não caiu", "seq 4", "é o de ontem", "seq 5", "R$ 1.200")
      expect(pending).not_to include("Olá! Como posso ajudar?")
      expect(history).to include("seq 1", "oi", "seq 2", "Olá! Como posso ajudar?")
      expect(card).to include("context_version", ">5<", "Contexto conferido",
                              turn.context_digest.delete_prefix("sha256:").first(12))
    end

    it "contexto divergente" do
      turn = grouped_turn
      turn.update_columns(context: turn.context.merge("history" => []))

      expect(turn_card(page_for(turn.ticket), 2)).to include("Contexto diverge do gravado")
    end

    it "turno sem digest" do
      turn = record_turn_06(ingest("oi").ticket, context_version: nil, digest: nil)

      expect(turn_card(page_for(turn.ticket), 1)).to include("Turno anterior ao bloco 06")
    end

    it "escape: o texto do cliente no contexto do turno não vira HTML" do
      turn = grouped_turn(last_text: "<script>alert(1)</script>")
      card = turn_card(page_for(turn.ticket), 2)

      expect(card).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(card).not_to include("<script>alert(1)</script>")
    end

    it "marca errada: a conversa de uma marca não mostra o contexto da outra" do
      create(:brand, :jim)
      mine = grouped_turn
      jim = record_turn_06(ingest("segredo da JIM", brand: "jim", identity: "acc_jim_000021").ticket)

      expect(page_for(mine.ticket)).not_to include("segredo da JIM")
      expect(page_for(jim.ticket)).not_to include("meu repasse não caiu")
    end
  end

  describe "linha do tempo" do
    it "mostra a janela, o teto, a abertura do turno e a recusa por contexto_excede_limite" do
      first = ingest("meu repasse não caiu")
      travel_to(t0 + 1.second)
      ingest("é o de ontem")
      travel_to(t0 + 3.seconds)
      ingest("R$ 1.200")
      travel_to(t0 + 4.seconds)
      turn = record_turn_06(first.ticket, context_version: 3)
      travel_to(t0 + 5.seconds)
      ingest("x" * 30)
      travel_to(t0 + 6.5.seconds)
      record_context_too_large(first.ticket, pending_chars: 16_800)

      get timeline_path(first.ticket.id)

      body = response.body
      expect(body).to include("Espera intencional (janela de agrupamento)", "janela de 1500 ms no chat",
                              "teto de 4 s atingido", "context_version 3", "Abertura do turno",
                              "pendentes seq 1, 2, 3", turn.context_digest.delete_prefix("sha256:").first(12),
                              "Turno não aberto", "contexto_excede_limite", "16800 caracteres pendentes",
                              "limite de 16000")
    end
  end
end
