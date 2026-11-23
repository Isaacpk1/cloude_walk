require "rails_helper"

# ROADMAP 10, Frontend, na conversa e na linha do tempo: resumo (RN-39, RN-40), aviso de transferência e o estado da
# entrega dele (RN-42, RN-38, RF-43), prioridade (RN-41) e fila de escalas (RF-42); na linha do tempo, o pedido do
# cliente (RN-34), a subida de prioridade, o resumo e a entrega do aviso. Registros no formato combinado do bloco 10.
RSpec.describe "ROADMAP 10: handoff na conversa e na linha do tempo" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 22, 13, 0, 0) }
  let!(:ticket) { at(t0) { ingest("meu repasse não caiu").ticket } }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def doc = Nokogiri::HTML(response.body)
  def card(css) = doc.at_css("section.card.#{css}")

  def escalate(reason: "pedido_do_cliente", source: "ingestion", time: t0 + 2.seconds, **)
    at(time) { record_full_escalation(ticket, record_handoff_requested(ticket, reason:, source:), **) }
  end

  def notice = Delivery.find_by!(ticket_id: ticket.id, kind: "handoff_notice")

  def show(time = t0 + 10.seconds)
    at(time) { get conversation_path(ticket.id) }
    expect(response).to have_http_status(:ok)
  end

  def timeline(time = t0 + 10.seconds)
    at(time) { get timeline_path(ticket.id) }
    expect(response).to have_http_status(:ok)
    doc.css(".timeline tbody tr").map { _1.text.squish }
  end

  describe "RN-39, RN-40: resumo na conversa" do
    it "disponível: os cinco campos com o rótulo e a origem" do
      escalate(summary: HumanQueueRecordHelpers::SUMMARY)

      show

      text = card("handoff-summary").text.squish
      expect(text).to include("Resumo disponível (do agente)", "Problema relatado", "Repasse de R$ 1.200 do dia 28 não recebido",
                              "Dados relevantes do cliente", "Ações já tomadas e resultados", "Motivo da escalação",
                              "O que está pendente", "Verificar retenção")
    end

    it "da plataforma, com o tempo desde a escalação (RNF-06)" do
      escalate
      at(t0 + 3.5.seconds) { record_summary(ticket, status: "available") }

      show

      expect(card("handoff-summary").text.squish).to include("Resumo disponível (da plataforma)", "1500 ms depois da escalação")
    end

    it "sem resumo: a marcação e o motivo, e o histórico continua na conversa (RN-40, RF-41)" do
      escalate
      at(t0 + 2.2.seconds) { record_summary(ticket, status: "missing", missing_reason: "historico_vazio") }

      show

      expect(card("handoff-summary").text.squish).to include("Sem resumo: histórico vazio, nada a resumir (RN-40)",
                                                             "O histórico completo está nesta conversa")
      expect(doc.css(".message").map { _1.text.squish }.join).to include("meu repasse não caiu")
    end

    it "pendente enquanto o worker não gravou" do
      escalate

      show

      expect(card("handoff-summary").text.squish).to include("Resumo pendente")
    end
  end

  describe "RN-42, RN-38: aviso de transferência e a entrega dele" do
    it "pendente, com o texto da marca, como mensagem do sistema" do
      escalate

      show

      text = card("transfer-notice").text.squish
      expect(text).to include("Aviso de transferência", "seq 2", "Pendente", notice.delivery_id.first(8))
      expect(doc.at_css("#seq-2.message--system").text).to include("Sistema", "Estou te transferindo para um especialista")
    end

    it "pendente atrás de uma saída em conciliação: diz qual seq segura o aviso" do
      turn = at(t0 + 1.second) { record_turn_06(ticket) }
      sending = at(t0 + 1.5.seconds) { record_outbound(turn) }
      at(t0 + 1.6.seconds) do
        record_delivery_sending(sending)
        sending.update_columns(lease_until: nil)
        record_reconciliation_needed(sending, attempts: 6)
      end
      escalate

      show

      expect(card("transfer-notice").text.squish).to include("Pendente: aguardando a conciliação da seq 2 (RN-38)")
    end

    it "enviando, em conciliação e entregue" do
      escalate
      at(t0 + 3.seconds) { record_delivery_sending(notice) }
      show
      expect(card("transfer-notice").text.squish).to include("Enviando")

      at(t0 + 4.seconds) { record_reconciliation_needed(notice, attempts: 6) }
      show
      expect(card("transfer-notice").text.squish).to include("Em conciliação")

      at(t0 + 5.seconds) { record_delivery_delivered(notice) }
      show
      expect(card("transfer-notice").text.squish).to include("Entregue")
    end
  end

  describe "RN-41, RF-42: prioridade e fila de escalas" do
    it "mostra a fila de escalas com a versão e a prioridade que subiu" do
      ticket.update_columns(priority: "media")
      escalate(reason: "prazo_do_turno", source: "scheduler")

      show

      text = card("handoff").text.squish
      expect(text).to include("Na fila humana: Escalas N1", "Escalas N1 · versão 1 (fila de escalas)", "alta",
                              "subiu: média → alta (RN-41)")
    end

    it "a conversa escuta o próprio stream" do
      show

      stream = doc.at_css("turbo-cable-stream-source")["signed-stream-name"]
      expect(Turbo::StreamsChannel.verified_stream_name(stream))
        .to eq(Turbo::StreamsChannel.send(:stream_name_from, ConversationView.stream_for("infinitepay", ticket.id)))
    end
  end

  describe "linha do tempo" do
    it "RN-34: pedido de humano do cliente, com o desfecho" do
      at(t0 + 1.second) do
        record_human_requested(ticket, seq: 1, outcome: "handoff_pedido", outbox_event_id: 77)
        record_human_requested(ticket, seq: 1, outcome: "handoff_ja_pedido")
        record_human_requested(ticket, seq: 1, outcome: "registrado", state: "aguardando_humano")
      end

      rows = timeline

      expect(rows.grep(/Pedido de humano pelo cliente/).size).to eq(3)
      expect(rows.join).to include("pedido de handoff gravado (item 77 no outbox)",
                                   "já havia um pedido de handoff nesta atribuição",
                                   "caso já com humano (aguardando_humano): só registrado")
    end

    it "RN-41: prioridade que subiu" do
      ticket.update_columns(priority: "media")
      escalate(reason: "teto_do_ciclo", source: "scheduler")

      expect(timeline.grep(/Prioridade subiu/).sole).to include("média → alta", "Teto do ciclo vencido")
    end

    it "RN-39, RN-40: resumo disponível e sem resumo, com o tempo desde a escalação" do
      escalate
      at(t0 + 2.8.seconds) { record_summary(ticket, status: "available") }

      expect(timeline.grep(/Resumo disponível/).sole).to include("da plataforma", "800 ms")
    end

    it "sem resumo com o motivo" do
      escalate
      at(t0 + 2.3.seconds) { record_summary(ticket, status: "missing", missing_reason: "erro_ao_montar") }

      expect(timeline.grep(/Sem resumo/).sole).to include("erro ao montar o resumo", "300 ms")
    end

    it "RN-42: a entrega do aviso de transferência" do
      escalate
      at(t0 + 3.seconds) { record_delivery_sending(notice) }
      at(t0 + 3.2.seconds) { record_delivery_delivered(notice) }

      rows = timeline
      expect(rows.grep(/Saída gravada para entrega/).sole).to include("aviso de transferência (handoff_notice)")
      expect(rows.grep(/Entrega ao canal/).sole).to include("seq 2")
    end
  end
end
