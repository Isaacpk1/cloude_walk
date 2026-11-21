require "rails_helper"

# ROADMAP 07, Frontend: turno superado e motivo da rejeição na linha do tempo, com links entre as mensagens
# e os turnos (RN-56, RF-56). Os registros vêm do caminho real (spec/support/race_records.rb): ingestão,
# Deadlines::DispatchDue, Turns::Open, mensagem 2 e AgentActions::Apply.
RSpec.describe "RN-56, RF-56: turno superado no painel" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  def rows(body) = Nokogiri::HTML(body).css("table.timeline tbody tr")
  def row_for(body, label) = rows(body).select { _1.at_css(".timeline__pick strong")&.text == label }

  describe "RN-56: linha do tempo" do
    it "mostra o evento Turno superado com o turno, a mensagem que superou e o horário, no horário do commit da mensagem 2" do
      race = record_three_second_race

      get timeline_path(race[:ticket].id)

      superseded = row_for(response.body, "Turno superado").sole
      expect(superseded.text).to include("Turno 1 superado pela mensagem seq 2",
                                         PanelClock.format(race[:t0] + 3.seconds, precise: true))
      expect(superseded.text).to include("seq 2", "turno 1")
      labels = rows(response.body).map { _1.at_css(".timeline__pick strong").text }
      persisted_seq2 = labels.each_index.select { labels[_1] == "Gravação" }.last
      expect(labels.index("Turno superado")).to be > persisted_seq2
      expect(labels.index("Turno superado")).to be < labels.index("Descarte da resposta")
    end

    it "liga a rejeição da resposta do turno 1 ao turno superado, com o motivo" do
      race = record_three_second_race
      expect(race[:rejected].reason).to eq("turno_superado")
      expect(race[:applied].status).to eq(:applied)

      get timeline_path(race[:ticket].id)

      discarded = row_for(response.body, "Descarte da resposta").sole
      expect(discarded.text).to include("Turno superado por mensagem nova do cliente")
      expect(discarded.text).to include("turno 1 superado pela mensagem seq 2")
      expect(discarded.at_css(%(a[href="/conversas/#{race[:ticket].id}#turn-1"]))).to be_present
    end

    it "cada evento com turno leva a #turn-N e cada evento com seq leva a #seq-N da conversa" do
      race = record_three_second_race
      id = race[:ticket].id

      get timeline_path(id)

      rows(response.body).each do |row|
        cell = row.css("td")[4]
        seq = cell.text[/seq (\d+)/, 1]
        turn = cell.text[/turno (\d+)/, 1]
        expect(cell.at_css(%(a[href="/conversas/#{id}#seq-#{seq}"]))).to be_present if seq
        expect(cell.at_css(%(a[href="/conversas/#{id}#turn-#{turn}"]))).to be_present if turn
      end
      superseded = row_for(response.body, "Turno superado").sole
      expect(superseded.at_css(%(a[href="/conversas/#{id}#seq-2"]))).to be_present
      expect(superseded.at_css(%(a[href="/conversas/#{id}#turn-1"]))).to be_present
    end

    it "sem nova mensagem não há turno superado" do
      ticket = travel_to(race_t0) { ingest("meu repasse não caiu").ticket }

      get timeline_path(ticket.id)

      expect(row_for(response.body, "Turno superado")).to be_empty
    end

    it "marca errada: a auditoria de outro atendimento (outra marca) não entra na linha do tempo" do
      race = record_three_second_race
      other = travel_to(race_t0) { ingest("oi", brand: "jim", identity: "acc_jim_000021").ticket }
      AuditEvent.create!(brand_id: jim.id, ticket: other, actor_type: "customer", event_type: "ai_turn.superseded",
                         trace_id: SecureRandom.hex(16), data: { turns: [ 7 ], by_seq: 9 })

      get timeline_path(other.id)
      expect(row_for(response.body, "Turno superado").sole.text).to include("Turno 7 superado pela mensagem seq 9")

      get timeline_path(race[:ticket].id)
      expect(row_for(response.body, "Turno superado").map(&:text).join).not_to include("Turno 7")
    end
  end

  describe "RN-56, RF-56: conversa" do
    it "cada mensagem tem id seq-N e diz em que turnos entrou, com links #turn-N" do
      race = record_three_second_race

      get conversation_path(race[:ticket].id)

      doc = Nokogiri::HTML(response.body)
      seq1 = doc.at_css("li#seq-1")
      seq2 = doc.at_css("li#seq-2")
      expect(seq1.text).to include("entrou nos turnos")
      expect(seq1.css("a.message__turn").map { _1["href"] }).to eq([ "#turn-1", "#turn-2" ])
      expect(seq2.css("a.message__turn").map { _1["href"] }).to eq([ "#turn-2" ])
    end

    it "o turno superado diz por qual mensagem e quando, com link #seq-M, e lista as mensagens que entraram" do
      race = record_three_second_race

      get conversation_path(race[:ticket].id)

      doc = Nokogiri::HTML(response.body)
      turn1 = doc.at_css("li#turn-1")
      superseded = turn1.at_css(".turn__superseded")
      expect(superseded.text).to include("superado pela mensagem seq 2", PanelClock.format(race[:t0] + 3.seconds))
      expect(superseded.at_css(%(a[href="#seq-2"]))).to be_present
      expect(turn1.css(".turn__messages a").map { _1["href"] }).to eq([ "#seq-1" ])
      turn2 = doc.at_css("li#turn-2")
      expect(turn2.at_css(".turn__superseded")).to be_nil
      expect(turn2.css(".turn__messages a").map { _1["href"] }).to eq([ "#seq-1", "#seq-2" ])
    end

    it "os links das duas páginas apontam para âncoras que existem na conversa" do
      race = record_three_second_race
      id = race[:ticket].id

      get conversation_path(id)
      doc = Nokogiri::HTML(response.body)
      anchors = doc.css("[id]").map { _1["id"] }
      internal = doc.css("a[href^='#']").map { _1["href"].delete_prefix("#") }
      get timeline_path(id)
      from_timeline = Nokogiri::HTML(response.body).css("a[href^='/conversas/#{id}#']").map { _1["href"].split("#").last }

      expect(internal).not_to be_empty
      expect(from_timeline).to include("turn-1", "seq-2")
      expect(anchors).to include(*internal, *from_timeline)
    end

    it "escapa o texto das mensagens nos links do turno" do
      t0 = race_t0
      ticket = travel_to(t0) { ingest("<script>alert(1)</script>").ticket }
      travel_to(t0 + 1.5.seconds) do
        Deadlines::DispatchDue.call(now: Time.current, limit: 100).each { Turns::Open.call(_1) }
      end
      travel_to(t0 + 3.seconds) { ingest("<b>mais</b>") }

      get conversation_path(ticket.id)

      expect(response.body).not_to include("<script>alert(1)</script>", "<b>mais</b>")
      expect(response.body).to include("&lt;script&gt;")
    end
  end
end
