require "rails_helper"

# Fila humana do painel (ROADMAP 10, Frontend; RF-42, RF-45, RN-29, RN-39, RN-40, RN-41). Registros no formato
# combinado do bloco 10 (spec/support/human_queue_records.rb).
RSpec.describe HumanQueue do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 22, 13, 0, 0) }

  def at(time, &) = travel_to(time, with_usec: true, &)

  # Um caso escalado em `time`, com a prioridade que tinha antes (nil: sem triagem) e o motivo.
  def escalated(time, identity:, brand: "infinitepay", priority: nil, reason: "pedido_do_cliente", source: "ingestion", **)
    at(time) do
      ticket = ingest("quero falar com um atendente", brand:, identity:).ticket
      ticket.update_columns(priority:)
      request = record_handoff_requested(ticket, reason:, source:)
      record_full_escalation(ticket, request, **)
      ticket.reload
    end
  end

  def entries(slug = nil) = at(t0 + 1.minute) { described_class.new(brand_slug: slug).entries }

  describe "RN-29: ordem da fila" do
    it "prioridade primeiro (crítica, alta, média, baixa; sem triagem conta como média), depois o mais antigo na fila" do
      baixa = escalated(t0, identity: "acc_1", priority: "baixa")
      media_nova = escalated(t0 + 3.seconds, identity: "acc_2", priority: "media")
      sem_triagem_antiga = escalated(t0 + 1.second, identity: "acc_3")
      critica = escalated(t0 + 5.seconds, identity: "acc_4", priority: "critica")
      alta = escalated(t0 + 4.seconds, identity: "acc_5", priority: "alta")

      expect(entries.map(&:ticket_id)).to eq([ critica, alta, sem_triagem_antiga, media_nova, baixa ].map(&:id))
    end

    it "só casos em aguardando_humano: o caso ainda com a IA e o já com analista não entram" do
      waiting = escalated(t0, identity: "acc_1")
      at(t0) { ingest("meu repasse não caiu", identity: "acc_2") }
      escalated(t0, identity: "acc_3").update_columns(state: "com_analista")

      expect(entries.map(&:ticket_id)).to eq([ waiting.id ])
    end

    it "tempo na fila: desde o ticket.escalated da atribuição atual" do
      escalated(t0, identity: "acc_1")

      entry = entries.sole
      expect(entry.escalated_at).to eq(t0)
      expect(entry.waiting_ms(t0 + 61.5.seconds)).to eq(61_500)
      expect(entry.waiting_text(t0 + 61.5.seconds)).to eq("1 min 1 s")
    end
  end

  describe "repetição: dois ticket.escalated do mesmo caso" do
    it "o caso aparece uma vez só, com o tempo do último" do
      ticket = escalated(t0, identity: "acc_1")
      at(t0 + 10.seconds) do
        request = record_handoff_requested(ticket.tap { _1.update_columns(state: "com_ia") }, reason: "prazo_do_turno", source: "scheduler")
        record_full_escalation(ticket, request)
      end

      entry = entries.sole
      expect(entry.ticket_id).to eq(ticket.id)
      expect(entry.escalated_at).to eq(t0 + 10.seconds)
      expect(entry.reason).to eq("prazo_do_turno")
    end
  end

  describe "isolamento por marca (invariante 6)" do
    before do
      escalated(t0, identity: "acc_ip")
      escalated(t0, identity: "acc_jim", brand: "jim")
    end

    it "com ?marca=, só os casos da marca" do
      expect(entries("infinitepay").map(&:brand_slug)).to eq(%w[infinitepay])
      expect(entries("jim").map(&:brand_slug)).to eq(%w[jim])
    end

    it "sem marca, as duas, cada linha com a sua marca" do
      expect(entries.map(&:brand_slug)).to contain_exactly("infinitepay", "jim")
    end

    it "marca desconhecida é NotFound" do
      expect { described_class.new(brand_slug: "outra") }.to raise_error(HumanQueue::NotFound)
    end

    it "a fila mostrada é a da marca do caso, mesmo com uma fila de outra marca no mesmo id de versão" do
      expect(entries("jim").sole.queue_name).to eq("Escalas N1")
      expect(HelpdeskQueue.find(entries("jim").sole.queue_id).brand_id).to eq(jim.id)
    end
  end

  describe "RF-42: fila, versão e origem" do
    it "fila de escalas com a versão, motivo e origem legíveis" do
      escalated(t0, identity: "acc_1")

      entry = entries.sole
      expect(entry).to have_attributes(queue_name: "Escalas N1", queue_version: 1, queue_kind: "escalation",
                                       reason: "pedido_do_cliente", source: "ingestion")
      expect(entry.queue_label).to eq("Escalas N1 · versão 1 (fila de escalas)")
      expect(entry.reason_label).to eq("Pedido explícito do cliente (RN-34)")
      expect(entry.source_label).to eq("Ingestão: mensagem do cliente")
    end

    it "sem fila de escalas, a padrão; sem nenhuma, sem fila" do
      escalated(t0, identity: "acc_1", queue_kind: "default")
      escalated(t0 + 1.second, identity: "acc_2", queue_kind: "missing")

      labels = entries.map(&:queue_label)
      expect(labels.first).to eq("Atendimento geral · versão 1 (fila padrão: a marca não tem fila de escalas)")
      expect(labels.last).to eq("Sem fila: a marca não tem fila de escalas nem padrão")
    end

    it "todo motivo do Handoff::Request tem texto legível, e toda origem também" do
      Handoff::Request::REASONS.each { expect(ConversationView::Handoff::REASONS).to have_key(_1) }
      Handoff::Request::SOURCES.each { expect(ConversationView::Handoff::SOURCES).to have_key(_1) }
    end
  end

  describe "RN-41: prioridade" do
    it "escalação por prazo sobe um nível: mostra de onde para onde" do
      escalated(t0, identity: "acc_1", priority: "media", reason: "prazo_do_turno", source: "scheduler")

      entry = entries.sole
      expect(entry.priority).to eq("alta")
      expect(entry.priority_label).to eq("alta")
      expect(entry.priority_raise_label).to eq("subiu: média → alta (RN-41)")
    end

    it "pedido do cliente mantém a prioridade, sem a marca de subida; sem triagem aparece como média" do
      escalated(t0, identity: "acc_1")

      entry = entries.sole
      expect(entry.priority_label).to eq("média (sem triagem, RN-13)")
      expect(entry.priority_raise_label).to be_nil
    end
  end

  describe "RN-39, RN-40: estado do resumo" do
    it "pendente enquanto o worker não gravou" do
      escalated(t0, identity: "acc_1")

      expect(entries.sole.summary).to have_attributes(status: :pending, label: "Resumo pendente")
    end

    it "disponível, vindo do agente" do
      escalated(t0, identity: "acc_1", summary: HumanQueueRecordHelpers::SUMMARY)

      expect(entries.sole.summary).to have_attributes(status: :available, source: "agent",
                                                      label: "Resumo disponível (do agente)")
    end

    it "disponível, montado pela plataforma" do
      ticket = escalated(t0, identity: "acc_1")
      at(t0 + 1.2.seconds) { record_summary(ticket, status: "available") }

      expect(entries.sole.summary).to have_attributes(status: :available, source: "platform", ms_since_escalated: 1200,
                                                      label: "Resumo disponível (da plataforma)")
    end

    it "sem resumo, com o motivo" do
      ticket = escalated(t0, identity: "acc_1")
      at(t0 + 0.4.seconds) { record_summary(ticket, status: "missing", missing_reason: "historico_vazio") }

      expect(entries.sole.summary).to have_attributes(status: :missing, missing_reason: "historico_vazio",
                                                      label: "Sem resumo: histórico vazio, nada a resumir (RN-40)")
    end

    it "resumo de uma escalação anterior não vale para a atual" do
      ticket = escalated(t0, identity: "acc_1", summary: HumanQueueRecordHelpers::SUMMARY)
      at(t0 + 10.seconds) do
        request = record_handoff_requested(ticket.tap { _1.update_columns(state: "com_ia") }, reason: "prazo_do_turno", source: "scheduler")
        record_full_escalation(ticket, request)
      end

      expect(entries.sole.summary.status).to eq(:pending)
    end
  end
end
