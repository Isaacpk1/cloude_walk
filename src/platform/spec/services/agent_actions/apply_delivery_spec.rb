require "rails_helper"

# Bloco 05: a saída gravada na mesma transação da ação aplicada (07, seção 3.1, passo 6: "a mesma transação
# grava o resultado, a auditoria (RN-37) e, quando houver mensagem de saída, a entrega no outbox"; 07, seções
# 3.2 e 4, `deliveries`). O envio ao provedor é do worker (Deliveries::Send), fora daqui (invariante 2).
RSpec.describe AgentActions::Apply, "RF-31, RF-06: saída gravada na aplicação da ação do agente" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:turn) { opened_turn }
  let(:ticket) { turn.ticket }

  def apply(action, traceparent: AgentActionHelpers::TRACEPARENT) = described_class.call(action, traceparent:)
  def outbound = Message.where(ticket_id: ticket.id, direction: "outbound")
  def requested = OutboxEvent.where(ticket_id: ticket.id, event_type: "delivery.requested")
  def output_counts = [ outbound.count, Delivery.where(ticket_id: ticket.id).count, requested.count,
                        AuditEvent.where(ticket_id: ticket.id, event_type: "delivery.requested").count ]

  def resolve_action(turn, text: nil)
    agent_action_for(turn, action: "resolve",
                           resolution: { "reason" => "duvida_respondida", "text" => text }.compact).except("reply")
  end

  def escalate_action(turn)
    agent_action_for(turn, action: "escalate", escalation: {
      "reason" => "retencao_suspeita", "summary" => { "problema" => "Repasse retido", "dados_cliente" => "Lojista",
                                                      "acoes_tomadas" => "Consultou o repasse", "motivo" => "Retenção",
                                                      "pendente" => "Verificar retenção" }
    }).except("reply")
  end

  describe "RF-31, RF-06, RNF-14, RNF-15: reply aplicado" do
    it "grava a mensagem de saída com o próximo seq, o canal e a conta da última mensagem do cliente" do
      before_call = db_now

      expect(apply(agent_action_for(turn)).status).to eq(:applied)

      message = outbound.sole
      expect(message).to have_attributes(
        brand_id: infinitepay.id, direction: "outbound", author_type: "bot", author_id: nil, internal: false,
        body: "Seu repasse de R$ 1.200 cai hoje até as 18h.", seq: 2, channel: "chat",
        provider_account: "infinitepay-chat-mock", external_id: nil, trace_id: AgentActionHelpers::TRACE_ID
      )
      expect(message.received_at).to be_between(before_call, db_now)
      expect(message.received_at).to eq(turn.reload.response_received_at)
    end

    it "grava a entrega pending com o mesmo seq, o kind reply, a versão da atribuição do turno e o trace" do
      ticket.update_columns(assignment_version: 3)
      turn.update_columns(assignment_version: 3)

      apply(agent_action_for(turn.reload))

      delivery = Delivery.where(ticket_id: ticket.id).sole
      expect(delivery).to have_attributes(
        brand_id: infinitepay.id, message_id: outbound.sole.id, seq: 2, channel: "chat",
        provider_account: "infinitepay-chat-mock", kind: "reply", status: "pending", attempts: 0,
        ai_assignment_version: 3, ai_first_pending_seq: nil, trace_id: AgentActionHelpers::TRACE_ID,
        provider_message_id: nil, delivered_at: nil
      )
      expect(delivery.delivery_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "grava o item delivery.requested no outbox com a chave única da entrega, pronto para agora" do
      freeze_time do
        apply(agent_action_for(turn))

        delivery = Delivery.where(ticket_id: ticket.id).sole
        expect(requested.sole).to have_attributes(
          brand_id: infinitepay.id, dedup_key: "delivery:#{delivery.delivery_id}", trace_id: AgentActionHelpers::TRACE_ID,
          next_attempt_at: Time.current, completed_at: nil, attempts: 0,
          payload: { "delivery_id" => delivery.delivery_id, "ticket_id" => ticket.id, "seq" => 2 }
        )
      end
    end

    it "RN-37, RF-54, RF-56: audita delivery.requested pelo sistema, com o trace do turno" do
      apply(agent_action_for(turn))

      delivery = Delivery.where(ticket_id: ticket.id).sole
      audit = AuditEvent.where(ticket_id: ticket.id, event_type: "delivery.requested").sole
      expect(audit).to have_attributes(brand_id: infinitepay.id, actor_type: "system",
                                       trace_id: AgentActionHelpers::TRACE_ID)
      expect(audit.data).to eq("delivery_id" => delivery.delivery_id, "message_id" => outbound.sole.id, "seq" => 2,
                               "kind" => "reply", "turn" => 1, "context_until_seq" => 1,
                               "context_version" => 2)
      applied = AuditEvent.where(ticket_id: ticket.id, event_type: "agent_action.applied").sole
      expect(audit.id).to be > applied.id
    end

    it "RF-56: sem traceparent, a saída leva o trace do evento do turno no outbox" do
      apply(agent_action_for(turn), traceparent: nil)

      trace = OutboxEvent.find(turn.event_id).trace_id
      expect([ outbound.sole.trace_id, Delivery.sole.trace_id, requested.sole.trace_id ]).to all(eq(trace))
    end

    it "reply_to: a mensagem do cliente com seq = context_until_seq existe e tem external_id" do
      apply(agent_action_for(turn))

      covered = Message.find_by(ticket_id: ticket.id, brand_id: ticket.brand_id, seq: turn.reload.context_until_seq)
      expect(covered).to have_attributes(direction: "inbound", author_type: "customer")
      expect(covered.external_id).to be_present
    end

    it "RF-06: responde pela conta da última mensagem do cliente, mesmo que a primeira tenha vindo de outra" do
      first = ingest("meu repasse não caiu")
      msg = normalized_message(text: "é o de ontem").merge("provider_account" => "infinitepay-chat-reserva")
      Ingestion::Receive.call(msg, provider_payload: {})
      turn2 = open_turn_for(first)

      apply(agent_action_for(turn2))

      expect(Message.where(ticket_id: first.ticket.id, direction: "outbound").sole)
        .to have_attributes(seq: 3, provider_account: "infinitepay-chat-reserva")
      expect(Delivery.sole.provider_account).to eq("infinitepay-chat-reserva")
    end

    it "nada externo na transação (invariante 2): nenhuma chamada HTTP nem produção no Kafka" do
      expect(Outbox::BrokerClient).not_to receive(:new)

      expect { apply(agent_action_for(turn)) }.not_to(change { karafka.produced_messages.size })
    end

    it "acorda o worker depois do commit, com o ID do item do outbox" do
      apply(agent_action_for(turn))

      expect(OutboxJob).to have_been_enqueued.with(requested.sole.id)
    end

    it "se o Redis estiver fora, a saída já gravada fica no outbox para a recuperação (07, seção 6)" do
      allow(OutboxJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError)

      expect(apply(agent_action_for(turn)).status).to eq(:applied)
      expect(output_counts).to eq([ 1, 1, 1, 1 ])
    end
  end

  describe "RF-31, RN-36: resolve" do
    it "com resolution.text grava a saída com kind resolution" do
      apply(resolve_action(turn, text: "Que bom que caiu! Fico à disposição."))

      expect(outbound.sole).to have_attributes(body: "Que bom que caiu! Fico à disposição.", seq: 2, author_type: "bot")
      expect(Delivery.sole).to have_attributes(kind: "resolution", seq: 2, status: "pending")
      expect(AuditEvent.find_by!(event_type: "delivery.requested").data["kind"]).to eq("resolution")
    end

    it "sem resolution.text não grava saída" do
      expect(apply(resolve_action(turn)).status).to eq(:applied)
      expect(output_counts).to eq([ 0, 0, 0, 0 ])
    end
  end

  it "RN-42: escalate não grava saída neste bloco (o aviso de transferência é do bloco 10)" do
    expect(apply(escalate_action(turn)).status).to eq(:applied)
    expect(output_counts).to eq([ 0, 0, 0, 0 ])
  end

  describe "RN-56, invariante 4: ação não aplicada não grava saída" do
    it "turno superado pela mensagem 2 (turno_superado)" do
      expect(turn.context_until_seq).to eq(1)
      ingest("é o de ontem, R$ 1.200")

      expect(apply(agent_action_for(turn)).reason).to eq("turno_superado")
      expect(output_counts).to eq([ 0, 0, 0, 0 ])
    end

    it "prazo vencido pelo relógio do banco (prazo_vencido)" do
      allow(DatabaseClock).to receive(:now).and_return(turn.deadline_at)

      expect(apply(agent_action_for(turn)).reason).to eq("prazo_vencido")
      expect(output_counts).to eq([ 0, 0, 0, 0 ])
    end

    it "atribuição mudou (atribuicao_mudou) e in_reply_to divergente" do
      expect(apply(agent_action_for(turn, assignment_version: 9)).reason).to eq("atribuicao_mudou")
      expect(apply(agent_action_for(turn, in_reply_to: SecureRandom.uuid)).reason).to eq("in_reply_to_divergente")
      expect(output_counts).to eq([ 0, 0, 0, 0 ])
    end

    it "RN-56: a segunda ação final do mesmo turno não grava uma segunda saída" do
      apply(agent_action_for(turn))

      expect(apply(agent_action_for(turn, reply: { "text" => "Outra resposta" })).reason).to eq("turno_nao_elegivel")
      expect(output_counts).to eq([ 1, 1, 1, 1 ])
      expect(outbound.sole.body).to eq("Seu repasse de R$ 1.200 cai hoje até as 18h.")
    end
  end

  it "RN-47, RNF-15: a mesma ação entregue de novo grava um só conjunto de saída" do
    action = agent_action_for(turn)
    apply(action)

    expect(apply(action).status).to eq(:duplicate)
    expect(output_counts).to eq([ 1, 1, 1, 1 ])
  end

  it "RN-44, invariante 10: ação fora do contrato vai para a DLQ sem gravar saída" do
    expect(apply(agent_action_for(turn, reply: { "text" => " " })).status).to eq(:invalid)
    expect(output_counts).to eq([ 0, 0, 0, 0 ])
  end

  describe "ADR-014, invariante 6: marca" do
    it "a saída, a entrega, o outbox e a auditoria levam o brand_id do atendimento" do
      jim_turn = opened_turn("minha maquininha não liga", brand: "jim")

      apply(agent_action_for(jim_turn))

      jim_ticket = jim_turn.ticket
      expect(jim_ticket.brand_id).to eq(jim.id)
      expect(Message.find_by!(ticket_id: jim_ticket.id, direction: "outbound"))
        .to have_attributes(brand_id: jim.id, provider_account: "jim-chat-mock")
      expect(Delivery.sole).to have_attributes(brand_id: jim.id, ticket_id: jim_ticket.id)
      expect(OutboxEvent.find_by!(event_type: "delivery.requested").brand_id).to eq(jim.id)
      expect(AuditEvent.find_by!(event_type: "delivery.requested").brand_id).to eq(jim.id)
    end

    it "a ação de outra marca para o atendimento vai para a DLQ sem gravar saída" do
      expect(apply(agent_action_for(turn, brand: "jim")).reason).to eq("marca_divergente")
      expect(output_counts).to eq([ 0, 0, 0, 0 ])
    end
  end

  describe "RN-55, RF-33, 07 seção 3.4: o ciclo seguinte" do
    it "mensagem 1 → turno 1 → reply (saída 2) → mensagem 3 → turno 2 só com a 3 e a saída no histórico" do
      expect(apply(agent_action_for(turn)).status).to eq(:applied)

      third = ingest("e o de hoje?")
      expect(third.message.seq).to eq(3)
      expect(ticket.reload).to have_attributes(latest_customer_seq: 3, first_pending_seq: 3)

      turn2 = open_turn_for(third)

      expect(turn2).to have_attributes(turn: 2, context_until_seq: 3)
      expect(turn2.context["pending_messages"]).to eq([ { "seq" => 3, "text" => "e o de hoje?" } ])
      expect(turn2.context["history"]).to eq([
        { "seq" => 1, "author" => "customer", "text" => "meu repasse não caiu" },
        { "seq" => 2, "author" => "bot", "text" => "Seu repasse de R$ 1.200 cai hoje até as 18h." }
      ])

      expect(apply(agent_action_for(turn2, reply: { "text" => "O de hoje cai amanhã." })).status).to eq(:applied)
      expect(outbound.order(:seq).pluck(:seq)).to eq([ 2, 4 ])
      expect(Delivery.where(ticket_id: ticket.id).order(:seq).pluck(:seq, :kind)).to eq([ [ 2, "reply" ], [ 4, "reply" ] ])
    end
  end

  describe "RN-55, RF-33: versão do contexto na saída (07, seção 3.4)" do
    def version = ticket.reload.context_version

    it "a saída visível gravada sobe context_version em 1, na transação do applied" do
      expect(version).to eq(1)

      apply(agent_action_for(turn))

      expect(version).to eq(2)
    end

    it "resolve com texto sobe; resolve sem texto e escalate (sem saída) não sobem" do
      apply(resolve_action(turn))
      expect(version).to eq(1)

      other = opened_turn("outra conversa", identity: "acc_infinitepay_versao_esc")
      apply(escalate_action(other))
      expect(other.ticket.reload.context_version).to eq(1)

      third = opened_turn("terceira", identity: "acc_infinitepay_versao_res")
      apply(resolve_action(third, text: "Resolvido."))
      expect(third.ticket.reload.context_version).to eq(2)
    end

    it "RN-56: rejeição, segunda ação final e duplicata não sobem (repetição)" do
      action = agent_action_for(turn)
      expect(apply(agent_action_for(turn, assignment_version: 9)).reason).to eq("atribuicao_mudou")
      expect(version).to eq(1)

      apply(action)
      apply(action)
      apply(agent_action_for(turn, reply: { "text" => "Outra resposta" }))

      expect(version).to eq(2)
    end

    it "RN-44: ação inválida (DLQ) e de outra marca não sobem (marca errada)" do
      apply(agent_action_for(turn, reply: { "text" => " " }))
      apply(agent_action_for(turn, brand: "jim"))

      expect(version).to eq(1)
    end

    it "RN-56: turno superado não sobe; só a mensagem nova do cliente sobe" do
      expect(turn.context_until_seq).to eq(1)
      ingest("é o de ontem, R$ 1.200")
      expect(apply(agent_action_for(turn)).reason).to eq("turno_superado")

      expect(version).to eq(2)
    end
  end
end
