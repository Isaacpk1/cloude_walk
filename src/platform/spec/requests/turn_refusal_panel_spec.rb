require "rails_helper"

# Caminho real, sem atalhos no banco: a ingestão grava o ciclo, o scheduler (Deadlines::DispatchDue) registra a
# abertura e o Turns::Open recusa de forma terminal (RN-49 contexto_excede_limite, RN-46 prazo_vencido). A conversa
# deixa de mostrar a fase de agrupamento e mostra a recusa com o handoff pendente (bloco 10); a linha do tempo não
# promete um handoff que ainda não existe.
RSpec.describe "RN-49, RN-46, RN-55, RF-55, RF-56: recusa terminal do turno no painel, pelo caminho real" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }

  def ingest_at(at, text, **) = travel_to(at, with_usec: true) { ingest(text, **) }

  def tick_at(at)
    travel_to(at, with_usec: true) do
      Deadlines::DispatchDue.call(now: Time.current, limit: 100).map { Turns::Open.call(_1) }
    end
  end

  def page(path, at)
    travel_to(at, with_usec: true) { get path }
    expect(response).to have_http_status(:ok)
    response.body
  end

  def refusal_section(body) = body[/<section class="card turn-refusal".*?<\/section>/m]

  describe "RN-49: pendentes acima do limite" do
    let(:ticket) do
      ingest_at(t0, "a" * 9_000).ticket.tap do
        ingest_at(t0 + 0.5.seconds, "b" * 9_000)
        expect(tick_at(t0 + 2.seconds).map(&:status)).to include(:context_too_large)
      end
    end

    it "a conversa troca o agrupamento pela recusa com os números; o scheduler não fica devendo turno" do
      body = page(conversation_path(ticket.id), t0 + 30.seconds)

      expect(body).not_to include("Agrupando mensagens", "aguardando o scheduler")
      expect(refusal_section(body)).to include(
        "Turno não aberto: contexto_excede_limite — handoff pendente (bloco 10)", "seq 1, 2",
        "18000 caracteres pendentes", "limite de 16000"
      )
      expect(tick_at(t0 + 30.seconds)).to be_empty
    end

    it "a linha do tempo diz que o handoff está pendente, sem prometer que o caso foi para humano" do
      body = page(timeline_path(ticket.id), t0 + 30.seconds)

      expect(body).to include("Turno não aberto (contexto_excede_limite)", "18000 caracteres pendentes",
                              "handoff para humano pendente (bloco 10; RN-49)")
      expect(body).not_to include("o caso vai para humano")
    end

    it "mensagem nova do cliente: agrupa de novo, tenta um turno novo e recusa de novo (ainda acima)" do
      ticket
      ingest_at(t0 + 31.seconds, "alguém?")
      expect(refusal_section(page(conversation_path(ticket.id), t0 + 31.seconds))).to be_nil
      expect(page(conversation_path(ticket.id), t0 + 31.seconds)).to include("Agrupando mensagens", "seq 1, 2, 3")

      expect(tick_at(t0 + 33.seconds).map(&:status)).to eq([ :context_too_large ])

      section = refusal_section(page(conversation_path(ticket.id), t0 + 33.seconds))
      expect(section).to include("contexto_excede_limite", "seq 1, 2, 3", "18007 caracteres pendentes")
    end

    it "marca errada: a recusa de uma marca não aparece na conversa da outra" do
      other = ingest_at(t0, "oi da JIM", brand: "jim", identity: "acc_jim_000021").ticket
      ticket

      expect(refusal_section(page(conversation_path(other.id), t0 + 30.seconds))).to be_nil
    end
  end

  describe "RN-46: teto do ciclo vencido antes de o turno abrir" do
    it "a conversa e a linha do tempo mostram prazo_vencido com o prazo, e o agrupamento some" do
      ticket = ingest_at(t0, "meu repasse não caiu").ticket
      expect(tick_at(t0 + 60.seconds).map(&:status)).to eq([ :expired ])
      expect(ticket.reload.dispatch_due_at).to be_nil

      body = page(conversation_path(ticket.id), t0 + 61.seconds)
      expect(body).not_to include("Agrupando mensagens")
      expect(refusal_section(body)).to include("Turno não aberto: prazo_vencido — handoff pendente (bloco 10)",
                                               "seq 1", "teto do ciclo")

      timeline = page(timeline_path(ticket.id), t0 + 61.seconds)
      expect(timeline).to include("Turno não aberto (prazo_vencido)", "handoff para humano pendente (bloco 10; RN-46)")
    end
  end
end
