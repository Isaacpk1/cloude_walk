require "rails_helper"

# Bloco 10: o handoff que nasce da ação do agente (RN-33, itens 1 e 6; 07, seções 3.2 e 3.4).
RSpec.describe AgentActions::Apply, "RN-33: handoff pela ação do agente" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  let(:summary) do
    { "problema" => "Repasse de R$ 1.200 retido", "dados_cliente" => "Lojista verificado",
      "acoes_tomadas" => "Consultou o repasse: pendente", "motivo" => "Retenção suspeita", "pendente" => "Verificar a retenção" }
  end

  def apply(action) = described_class.call(action, traceparent: AgentActionHelpers::TRACEPARENT)
  def escalate_action(turn) = agent_action_for(turn, action: "escalate", escalation: { "reason" => "retencao_suspeita", "summary" => summary }).except("reply")
  def requests(ticket) = handoff_items(ticket)

  describe "RN-33 (item 1), RF-39: escalate válida" do
    it "pede o handoff decisao_do_agente na transação do applied, com o resumo do agente e sem saída ao cliente" do
      turn = opened_turn
      ticket = turn.ticket

      result = apply(escalate_action(turn))

      expect(result.status).to eq(:applied)
      expect(turn.reload.status).to eq("applied") # uma ação final por turno: o Request não a desfaz
      item = requests(ticket).sole
      expect(item.payload).to include("reason" => "decisao_do_agente", "source" => "agent", "turn" => turn.turn,
                                      "assignment_version" => 0, "summary" => summary, "first_pending_seq" => 1)
      expect(item.trace_id).to eq(AgentActionHelpers::TRACE_ID)
      expect(Message.where(ticket_id: ticket.id, direction: "outbound")).to be_empty
      expect(Delivery.where(ticket_id: ticket.id)).to be_empty
      expect(audits(ticket, "agent_action.applied").sole.data).to include("handoff_event_id" => item.id)
      expect(audits(ticket, "handoff.requested").sole.data).to include("summary_from_agent" => true)
      expect(audits(ticket, "ai_turn.expired")).to be_empty
    end

    it "invariante 2: acorda o Escalate depois do commit; com o Redis fora, o pedido fica gravado para a recuperação" do
      turn = opened_turn
      apply(escalate_action(turn))
      expect(OutboxJob).to have_been_enqueued.with(requests(turn.ticket).sole.id)

      other = opened_turn("outro caso", identity: "acc_infinitepay_000099")
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "redis fora do ar")
      expect(apply(escalate_action(other)).status).to eq(:applied)
      expect(requests(other.ticket).sole.completed_at).to be_nil
    end

    it "RN-47 (repetição): a mesma escalate reentregue não grava um segundo pedido" do
      turn = opened_turn
      action = escalate_action(turn)

      apply(action)
      expect(apply(action).status).to eq(:duplicate)

      expect(requests(turn.ticket).count).to eq(1)
      expect(audits(turn.ticket, "handoff.requested").count).to eq(1)
    end

    it "RN-34 (ordem): com o handoff já pedido na atribuição, a escalate é rejeitada e não grava outro pedido" do
      turn = opened_turn
      first = request_handoff(turn.ticket, reason: "pedido_do_cliente", source: "ingestion", turn: turn.turn)

      result = apply(escalate_action(turn))

      expect(result.status).to eq(:rejected)
      expect(requests(turn.ticket).pluck(:id)).to eq([ first ])
    end

    it "invariante 6 (marca errada): escalate com a marca de outra empresa vai à DLQ sem pedido" do
      turn = opened_turn

      result = apply(escalate_action(turn).merge("brand" => "jim"))

      expect(result).to have_attributes(status: :rejected, reason: "marca_divergente")
      expect(handoff_items).to be_empty
    end
  end

  describe "RN-33 (item 6): limite de trocas" do
    let(:limit) { Handoff::Policy.for(infinitepay).exchanges_limit }

    # Uma troca: um turno com `reply` aplicado na atribuição atual da IA.
    def exchange(text: "mais uma dúvida", action: :reply)
      turn = opened_turn(text)
      payload = case action
      when :reply then agent_action_for(turn)
      when :resolve then agent_action_for(turn, action: "resolve", resolution: { "reason" => "duvida_respondida" }).except("reply")
      end
      expect(apply(payload).status).to eq(:applied)
      turn
    end

    it "o limite padrão é 10 (06, parâmetros)" do
      expect(limit).to eq(10)
    end

    it "cada reply aplicado soma 1 em ai_turns_count; 9 trocas não escalam" do
      turns = Array.new(9) { exchange }

      ticket = turns.last.ticket.reload
      expect(ticket.ai_turns_count).to eq(9)
      expect(requests(ticket)).to be_empty
      expect(audits(ticket, "agent_action.applied").last.data).to include("ai_turns_count" => 9)
    end

    it "a 10ª troca pede limite_de_trocas na mesma transação e a 10ª resposta tem seq menor que tudo depois" do
      turns = Array.new(10) { exchange }

      ticket = turns.last.ticket.reload
      expect(ticket.ai_turns_count).to eq(10)
      item = requests(ticket).sole
      expect(item.payload).to include("reason" => "limite_de_trocas", "source" => "agent", "turn" => turns.last.turn)
      expect(item.payload).not_to have_key("summary")
      tenth = Message.where(ticket_id: ticket.id, direction: "outbound").order(:seq).last
      expect(tenth.seq).to eq(Message.where(ticket_id: ticket.id).maximum(:seq))
      expect(Delivery.find_by!(message_id: tenth.id).status).to eq("pending") # a 10ª resposta sai
      expect(turns.last.reload.status).to eq("applied")
      expect(audits(ticket, "agent_action.applied").last.data).to include("ai_turns_count" => 10, "handoff_event_id" => item.id)
    end

    it "resolve no meio zera a contagem: 5 trocas, resolve, mais 5 trocas não escalam" do
      5.times { exchange }
      exchange(action: :resolve)
      turns = Array.new(5) { exchange }

      ticket = turns.last.ticket.reload
      expect(ticket.ai_turns_count).to eq(5)
      expect(requests(ticket)).to be_empty
    end

    it "escalate e resposta rejeitada não contam como troca" do
      turn = opened_turn
      ingest("mudei de ideia") # supera o turno 1
      apply(agent_action_for(turn))

      expect(turn.ticket.reload.ai_turns_count).to eq(0)
    end

    it "a contagem é por marca: trocas da JIM não somam no atendimento da InfinitePay" do
      9.times { exchange }
      jim_turn = opened_turn("oi", brand: "jim", identity: "acc_jim_000001")
      apply(agent_action_for(jim_turn))

      expect(Ticket.find_by!(brand_id: infinitepay.id).ai_turns_count).to eq(9)
      expect(jim_turn.ticket.reload.ai_turns_count).to eq(1)
      expect(handoff_items).to be_empty
    end
  end
end
