require "rails_helper"

# RF-37 (visualizar a DLQ), RN-45, RN-48: leitura de dead_letters para o painel. Registros no formato
# combinado do bloco 09 (spec/support/recovery_records.rb). Marca (invariante 6): sem filtro mostra todas as
# marcas e o que ficou sem correlação; com ?marca= só aquela marca, e fora dela é 404.
RSpec.describe DeadLetterPanel, "RF-37: DLQ no painel" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  before { travel_to(t0) }

  def ticket_with_turn(brand: "infinitepay")
    turn = open_turn_for(ingest(brand:))
    [ turn.ticket, turn ]
  end

  describe "lista" do
    it "mostra quando, origem, motivo, event_id, atendimento, turno e desfecho, da mais nova para a mais antiga" do
      ticket, turn = ticket_with_turn
      older = seed_dead_letter(ticket:, turn:, source: "broker", reason: "contrato", outcome: "escalated")
      travel_to(t0 + 5)
      newer = seed_dead_letter(source: "agent-mock", reason: "contrato", outcome: "uncorrelated")

      rows = described_class.new.all

      expect(rows.map(&:id)).to eq([ newer.id, older.id ])
      expect(rows.last).to have_attributes(created_at: t0, source: "broker", reason: "contrato", event_id: older.event_id,
                                           ticket_id: ticket.id, turn: 1, outcome: "escalated", brand_slug: "infinitepay",
                                           correlated?: true)
      expect(rows.last.source_label).to eq("Broker (publicação para o agente)")
      expect(rows.last.outcome_label).to eq("Escalou o atendimento: turno ainda válido (RN-45)")
      expect(rows.first).to have_attributes(correlated?: false, brand_slug: nil)
      expect(rows.first.outcome_label).to eq("Sem correlação confiável: nenhum atendimento alterado (RN-45)")
    end

    it "RN-45: só auditado (turno superado) e sem decisão registrada" do
      ticket, turn = ticket_with_turn
      audited = seed_dead_letter(ticket:, turn:, source: "platform", reason: "contrato", outcome: "audited")
      pending = seed_dead_letter(ticket:, turn:, outcome: nil)

      rows = described_class.new.all.index_by(&:id)

      expect(rows[audited.id].outcome_label).to eq("Só auditado: o turno já tinha sido superado, aplicado ou expirado (RN-45)")
      expect(rows[pending.id].outcome_label).to eq("Sem decisão registrada")
    end

    it "invariante 6: com a marca, só as dela; sem correlação fica de fora" do
      ticket, turn = ticket_with_turn
      mine = seed_dead_letter(ticket:, turn:)
      jim_ticket, jim_turn = ticket_with_turn(brand: "jim")
      seed_dead_letter(ticket: jim_ticket, turn: jim_turn)
      seed_dead_letter(outcome: "uncorrelated")

      expect(described_class.new(brand_slug: "infinitepay").all.map(&:id)).to eq([ mine.id ])
      expect(described_class.new.all.size).to eq(3)
    end

    it "marca inexistente é NotFound" do
      expect { described_class.new(brand_slug: "nao-existe") }.to raise_error(DeadLetterPanel::NotFound)
    end
  end

  describe "detalhe" do
    it "cabeçalhos, violações, corpo cru e a ligação ao atendimento e ao turno" do
      ticket, turn = ticket_with_turn
      dead_letter = seed_dead_letter(ticket:, turn:, payload: "{\"turn\": \"x\"}", violations: [ "/turn" ],
                                       error: "schema agent_inbound")

      view = described_class.new.find(dead_letter.id.to_s)

      expect(view).to have_attributes(ticket_id: ticket.id, turn: 1, violations: [ "/turn" ], error: "schema agent_inbound",
                                      topic: "helpdesk.agent.dlq.v1", partition: 3, attempts: 1)
      expect(view.payload_text).to eq("{\"turn\": \"x\"}")
      expect(view.headers_text).to include("\"dlq_reason\": \"contrato\"")
    end

    it "invariante 6: o registro de outra marca não aparece com o filtro da marca" do
      jim_ticket, jim_turn = ticket_with_turn(brand: "jim")
      dead_letter = seed_dead_letter(ticket: jim_ticket, turn: jim_turn)

      expect { described_class.new(brand_slug: "infinitepay").find(dead_letter.id.to_s) }.to raise_error(DeadLetterPanel::NotFound)
      expect(described_class.new(brand_slug: "jim").find(dead_letter.id.to_s).id).to eq(dead_letter.id)
    end

    it "sem correlação só aparece sem o filtro de marca" do
      dead_letter = seed_dead_letter(outcome: "uncorrelated")

      expect { described_class.new(brand_slug: "infinitepay").find(dead_letter.id.to_s) }.to raise_error(DeadLetterPanel::NotFound)
      expect(described_class.new.find(dead_letter.id.to_s)).to have_attributes(correlated?: false, ticket_id: nil)
    end

    it "id inexistente ou fora do formato é NotFound" do
      expect { described_class.new.find("999999") }.to raise_error(DeadLetterPanel::NotFound)
      expect { described_class.new.find("1 or 1=1") }.to raise_error(DeadLetterPanel::NotFound)
    end
  end

  describe DeadLetterView, "corpo cru de fora" do
    def view_for(payload) = DeadLetterView.from(DeadLetter.new(id: 1, source: "broker", reason: "contrato", payload:,
                                                               headers: {}, violations: [], attempts: 0, created_at: t0,
                                                               topic: "helpdesk.agent.dlq.v1", partition: 0, offset: 1))

    it "bytes que não são UTF-8 viram o caractere de substituição" do
      expect(view_for((+"ab\xFFcd").force_encoding(Encoding::BINARY)).payload_text).to eq("ab�cd")
    end

    it "caracteres de controle (\\u0000) aparecem escritos, sem sumir nem quebrar a página" do
      expect(view_for("a\u0000b\tc\nd").payload_text).to eq("a\\u0000b\tc\nd")
    end
  end
end
