require "rails_helper"

RSpec.describe SyntheticConversations do
  subject(:provider) { described_class.new }

  let(:conversations) { provider.all }

  it "oferece pelo menos três conversas, todas marcadas como exemplo sintético" do
    expect(conversations.size).to be >= 3
    expect(conversations.map(&:source)).to all(eq(DataSource::SYNTHETIC))
    expect(conversations.map(&:id).uniq.size).to eq(conversations.size)
  end

  it "é determinístico: duas leituras devolvem a mesma conversa" do
    expect(described_class.new.find("exemplo-repasse")).to eq(provider.find("exemplo-repasse"))
  end

  it "devolve nil para uma conversa que não existe" do
    expect(provider.find("nao-existe")).to be_nil
    expect(provider.timeline("nao-existe")).to be_nil
  end

  describe "ROADMAP 05: caminho feliz, meu repasse não caiu" do
    let(:view) { provider.find("exemplo-repasse") }

    it "tem a pergunta do cliente, um turno aplicado e a resposta entregue" do
      expect(view.messages.first).to have_attributes(seq: 1, author_type: "customer", body: "meu repasse não caiu")
      expect(view.turns.map(&:status)).to eq([ "applied" ])
      expect(view.messages.last).to have_attributes(author_type: "bot", delivery_status: "delivered")
      expect(view.assignee.kind).to eq("bot")
    end

    it "mostra a consulta feita pelo agente no turno" do
      expect(view.turns.first.tool_calls).to include("consultar_repasse")
    end

    it "RF-32, RN-37: o turno traz a ação recebida de exemplo, com consulta, agente e duração, na conversa sintética" do
      action = view.turns.first.agent_action

      expect(view.source).to eq(DataSource::SYNTHETIC)
      expect(action).to have_attributes(action: "reply", outcome: :applied, agent_ms: 2_000)
      expect(action.reply_text).to eq(view.messages.last.body)
      expect(action.tool_calls.sole).to have_attributes(tool: "consultar_repasse", duration_ms: be_positive)
      expect(action.model).to be_present
    end
  end

  describe "RN-56: corrida dos 3 s" do
    let(:view) { provider.find("exemplo-corrida-3s") }

    it "descarta o turno 1 como superado e o turno 2 cobre seq 1 e 2" do
      turn1, turn2 = view.turns

      expect(turn1).to have_attributes(number: 1, status: "superseded", covered_seqs: [ 1 ], context_until_seq: 1)
      expect(turn2).to have_attributes(number: 2, status: "applied", covered_seqs: [ 1, 2 ], context_until_seq: 2)
      expect(view.latest_customer_seq).to eq(2)
    end

    it "entrega uma única resposta ao cliente" do
      expect(view.messages.select { _1.author_type == "bot" }.size).to eq(1)
    end

    it "registra na linha do tempo o descarte da resposta do turno 1 e a aplicação do turno 2" do
      timeline = provider.timeline("exemplo-corrida-3s")

      expect(timeline.events_for_turn(1).map(&:kind)).to include(:discarded)
      expect(timeline.events_for_turn(2).map(&:kind)).to include(:applied)
      expect(timeline.events_for_turn(2).map(&:kind)).not_to include(:discarded)
    end

    it "abre o turno 2 no teto de 4 s desde a primeira mensagem pendente (RN-55)" do
      timeline = provider.timeline("exemplo-corrida-3s")
      wait = timeline.events_for_turn(2).find { _1.kind == :intentional_wait }

      expect(timeline.offset_ms(wait) + wait.duration_ms).to eq(4_000)
    end
  end

  describe "RN-33: escalação para humano" do
    let(:view) { provider.find("exemplo-escalacao") }

    it "passa o atendimento a um analista e guarda o histórico de escalação" do
      expect(view.assignee.kind).to eq("human")
      expect(view.escalations).not_to be_empty
      expect(view.escalations.first.from).to eq("Agente de IA")
      expect(view.assignment_version).to be > 1
    end

    it "tem mensagens de cliente, bot, sistema e analista" do
      expect(view.messages.map(&:author_type).uniq).to include("customer", "system", "analyst")
    end
  end

  describe "RF-56: linha do tempo" do
    it "liga todos os eventos ao ticket e ao trace da conversa" do
      conversations.each do |conversation|
        timeline = provider.timeline(conversation.id)

        expect(timeline.events.map(&:ticket_id)).to all(eq(conversation.ticket_id))
        expect(timeline.events.map(&:trace_id).compact).not_to be_empty
        expect(timeline.events.map(&:source)).to all(eq(DataSource::SYNTHETIC))
      end
    end

    it "cobre as etapas do fluxo do 07, seção 3.1" do
      kinds = provider.timeline("exemplo-repasse").events.map(&:kind)

      expect(kinds).to include(:received, :persisted, :intentional_wait, :published, :agent_run, :applied, :delivered)
    end
  end

  describe "RF-58: marcas e clientes do seed" do
    it "usa o nome da marca e do cliente do banco quando o seed já rodou" do
      brand = create(:brand, :infinitepay, name: "InfinitePay Seed")
      create(:customer, brand:, display_name: "Fulana Sintética")

      view = described_class.new.find("exemplo-repasse")

      expect(view).to have_attributes(brand_slug: "infinitepay", brand_name: "InfinitePay Seed", customer_name: "Fulana Sintética")
    end

    it "funciona sem o seed, com nomes sintéticos fixos" do
      expect(provider.find("exemplo-escalacao")).to have_attributes(brand_slug: "jim", brand_name: "JIM")
    end
  end
end
