require "rails_helper"

# ROADMAP 10, Frontend: "mostrar o caso na fila humana com motivo, histórico e estado do resumo" (RF-39 a RF-42,
# RF-45, RN-29, RN-39 a RN-41, RNF-06). Registros no formato combinado do bloco 10 (spec/support/human_queue_records.rb)
# e, no fim, o caminho real (Handoff::Request + Handoff::Escalate).
RSpec.describe "ROADMAP 10: fila humana no painel" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:t0) { Time.utc(2026, 11, 22, 13, 0, 0) }

  def at(time, &) = travel_to(time, with_usec: true, &)
  def doc = Nokogiri::HTML(response.body)
  def rows = doc.css(".human-queue__row")
  def row_for(ticket) = doc.at_css("#queue-ticket-#{ticket.id}")

  def escalated(time, identity:, brand: "infinitepay", priority: nil, reason: "pedido_do_cliente", source: "ingestion",
                text: "quero falar com um atendente", **)
    at(time) do
      ticket = ingest(text, brand:, identity:).ticket
      ticket.update_columns(priority:)
      record_full_escalation(ticket, record_handoff_requested(ticket, reason:, source:), **)
      ticket.reload
    end
  end

  def visit_queue(time = t0 + 1.minute, **params)
    at(time) { get human_queue_path(params) }
    expect(response).to have_http_status(:ok)
  end

  it "tem Fila humana no menu do painel" do
    get root_path

    expect(response.body).to include(%(href="#{human_queue_path}"))
    expect(doc.at_css(%(a[href="#{human_queue_path}"])).text).to eq("Fila humana")
  end

  it "fila vazia: diz que não há casos esperando" do
    visit_queue

    expect(doc.css(".human-queue").text).to include("Nenhum caso aguardando humano")
  end

  describe "RN-29: ordem" do
    it "prioridade e depois o mais antigo na fila, com a posição" do
      baixa = escalated(t0, identity: "acc_1", priority: "baixa")
      alta_nova = escalated(t0 + 2.seconds, identity: "acc_2", priority: "alta")
      alta_antiga = escalated(t0 + 1.second, identity: "acc_3", priority: "alta")

      visit_queue

      expect(rows.map { _1["id"] }).to eq([ alta_antiga, alta_nova, baixa ].map { "queue-ticket-#{_1.id}" })
      expect(rows.first.css(".human-queue__position").text).to eq("1")
    end
  end

  describe "RF-42, RF-45: o que cada linha mostra" do
    it "atendimento, marca, fila e versão, motivo, origem, prioridade, tempo na fila e links" do
      ticket = escalated(t0, identity: "acc_1")

      visit_queue(t0 + 75.seconds)

      text = row_for(ticket).text.squish
      expect(text).to include("##{ticket.id}", "quero falar com um atendente", "InfinitePay", "Escalas N1 · versão 1 (fila de escalas)",
                              "Pedido explícito do cliente (RN-34)", "Ingestão: mensagem do cliente",
                              "média (sem triagem, RN-13)", "1 min 15 s", "Resumo pendente")
      links = row_for(ticket).css("a").map { _1["href"] }
      expect(links).to include(conversation_path(ticket.id), timeline_path(ticket.id))
      expect(row_for(ticket).at_css("time")["datetime"]).to eq(t0.iso8601(3))
    end

    it "RN-41: a prioridade que subiu aparece com de onde para onde" do
      ticket = escalated(t0, identity: "acc_1", priority: "media", reason: "teto_do_ciclo", source: "scheduler")

      visit_queue

      expect(row_for(ticket).text.squish).to include("alta", "subiu: média → alta (RN-41)", "Teto do ciclo vencido")
    end

    it "todos os motivos do Handoff::Request aparecem em texto legível, nunca o código" do
      Handoff::Request::REASONS.each_with_index do |reason, i|
        escalated(t0 + i.seconds, identity: "acc_#{i}", reason:, source: "agent")
      end

      visit_queue

      reasons = doc.css(".human-queue__reason").map { _1.text.squish }
      expect(reasons).to match_array(Handoff::Request::REASONS.map { ConversationView::Handoff.reason_label(_1) })
      expect(reasons).not_to include(*Handoff::Request::REASONS)
    end

    it "conteúdo de fora é escapado" do
      ticket = escalated(t0, identity: "acc_1", text: "<script>alert(1)</script> quero falar com um atendente")

      visit_queue

      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(row_for(ticket).text).to include("<script>alert(1)</script>")
    end
  end

  describe "RN-39, RN-40: estado do resumo" do
    it "pendente, disponível do agente, disponível da plataforma e sem resumo com o motivo" do
      pending = escalated(t0, identity: "acc_1")
      agent = escalated(t0 + 1.second, identity: "acc_2", summary: HumanQueueRecordHelpers::SUMMARY)
      platform = escalated(t0 + 2.seconds, identity: "acc_3")
      missing = escalated(t0 + 3.seconds, identity: "acc_4")
      at(t0 + 4.seconds) do
        record_summary(platform, status: "available")
        record_summary(missing, status: "missing", missing_reason: "erro_ao_montar")
      end

      visit_queue

      summary = ->(ticket) { row_for(ticket).at_css(".human-queue__summary") }
      expect(summary[pending].text.squish).to eq("Resumo pendente")
      expect(summary[agent].text.squish).to eq("Resumo disponível (do agente)")
      expect(summary[platform].text.squish).to eq("Resumo disponível (da plataforma)")
      expect(summary[missing].text.squish).to eq("Sem resumo: erro ao montar o resumo (RN-40)")
      expect(summary[missing]["class"]).to include("human-queue__summary--missing")
    end
  end

  describe "repetição" do
    it "dois ticket.escalated do mesmo caso: uma linha só" do
      ticket = escalated(t0, identity: "acc_1")
      at(t0 + 5.seconds) do
        ticket.update_columns(state: "com_ia")
        record_full_escalation(ticket, record_handoff_requested(ticket, reason: "prazo_do_turno", source: "scheduler"))
      end

      visit_queue

      expect(rows.size).to eq(1)
      expect(row_for(ticket).text).to include("Prazo do turno vencido")
    end
  end

  describe "marca errada (invariante 6)" do
    let!(:ip_ticket) { escalated(t0, identity: "acc_ip") }
    let!(:jim_ticket) { escalated(t0, identity: "acc_jim", brand: "jim", text: "I want to talk to a human") }

    it "?marca= mostra só a marca e nunca um caso de outra" do
      visit_queue(marca: "infinitepay")

      expect(row_for(ip_ticket)).to be_present
      expect(row_for(jim_ticket)).to be_nil
      expect(response.body).not_to include("I want to talk to a human")
    end

    it "marca desconhecida é 404" do
      get human_queue_path(marca: "outra")

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("quero falar com um atendente")
    end

    it "sem marca, as duas, cada linha com a sua" do
      visit_queue

      expect(row_for(ip_ticket).text).to include("InfinitePay")
      expect(row_for(jim_ticket).text).to include("JIM")
    end

    it "a página escuta só o stream da própria marca (ou o geral sem marca)" do
      visit_queue(marca: "jim")
      jim_stream = doc.at_css("turbo-cable-stream-source")["signed-stream-name"]
      visit_queue
      general_stream = doc.at_css("turbo-cable-stream-source")["signed-stream-name"]

      expect(Turbo::StreamsChannel.verified_stream_name(jim_stream)).to eq(Turbo::StreamsChannel.send(:stream_name_from, [ :human_queue, jim ]))
      expect(Turbo::StreamsChannel.verified_stream_name(general_stream)).to eq("human_queue")
    end
  end

  describe "ponta a ponta: Handoff::Request e Handoff::Escalate reais até a /fila" do
    it "o pedido do cliente chega à fila com motivo, origem e resumo pendente" do
      default_queue_for(infinitepay, name: "Suporte InfinitePay")
      ticket = at(t0) { ingest("meu repasse não caiu", identity: "acc_1").ticket }
      id = at(t0 + 1.second) do
        ActiveRecord::Base.transaction do
          locked = Ticket.lock.find_by!(id: ticket.id, brand_id: infinitepay.id)
          Handoff::Request.call(ticket: locked, reason: "pedido_do_cliente", source: "ingestion", trace_id: "d" * 32)
        end
      end
      at(t0 + 1.2.seconds) { Handoff::Escalate.call(id) }

      visit_queue(t0 + 3.seconds, marca: "infinitepay")

      text = row_for(ticket).text.squish
      expect(text).to include("Suporte InfinitePay", "Pedido explícito do cliente (RN-34)", "Ingestão: mensagem do cliente",
                              "Resumo pendente")
      visit_queue(t0 + 3.seconds, marca: "jim")
      expect(row_for(ticket)).to be_nil
    end
  end
end
