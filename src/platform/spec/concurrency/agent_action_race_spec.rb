require "rails_helper"

# Aplicação da ação do agente com o Postgres de verdade, fora da transação de teste (AGENTS.md, item 3;
# 07, seção 3.4; invariantes 3, 4 e 8).
RSpec.describe "Aplicação da ação do agente com processos concorrentes", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }

  def apply(action) = AgentActions::Apply.call(action, traceparent: AgentActionHelpers::TRACEPARENT)

  describe "RN-47, RNF-15: duas entregas simultâneas da mesma ação" do
    it "produzem um único efeito" do
      turn = opened_turn
      action = agent_action_for(turn)

      results = run_concurrently(threads: 4) { apply(action) }

      expect(results.map(&:status).tally).to eq(applied: 1, duplicate: 3)
      expect([ Message.where(direction: "outbound").count, Delivery.count,
               OutboxEvent.where(event_type: "delivery.requested").count ]).to eq([ 1, 1, 1 ])
      expect(AuditEvent.where(event_type: [ "agent_action.applied", "agent_action.rejected" ]).count).to eq(1)
      expect(ProcessedEvent.count).to eq(1)
      expect(turn.reload).to have_attributes(status: "applied", applied_event_id: action["event_id"])
    end
  end

  describe "RN-56, RNF-15: duas ações finais diferentes para o mesmo turno ao mesmo tempo" do
    it "só uma é aplicada; a outra é rejeitada e não troca a response gravada" do
      turn = opened_turn
      actions = Array.new(2) { |i| agent_action_for(turn, reply: { "text" => "Resposta #{i}" }) }

      results = run_concurrently(threads: 2) { |i| apply(actions[i]) }

      expect(results.map(&:status)).to contain_exactly(:applied, :rejected)
      winner = actions[results.index { _1.status == :applied }]
      expect(results.find { _1.status == :rejected }.reason).to eq("turno_nao_elegivel")
      expect(turn.reload).to have_attributes(status: "applied", applied_event_id: winner["event_id"], response: winner)
      # Bloco 05: uma só saída, com o texto da vencedora.
      expect(Message.where(direction: "outbound").sole).to have_attributes(body: winner.dig("reply", "text"), seq: 2)
      expect([ Delivery.count, OutboxEvent.where(event_type: "delivery.requested").count ]).to eq([ 1, 1 ])
    end
  end

  describe "RN-56, invariante 4: mensagem nova do cliente concorrente com a aplicação" do
    it "nunca fica applied uma resposta que não cobre a mensagem gravada antes dela" do
      outcomes = Array.new(6) do |round|
        identity = "acc_infinitepay_corrida_#{round}"
        turn = opened_turn("meu repasse não caiu", identity:)
        action = agent_action_for(turn)

        results = run_concurrently(threads: 2) do |i|
          i.zero? ? apply(action) : ingest("é o de ontem, R$ 1.200", identity:)
        end
        raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

        ticket = turn.ticket.reload
        applied_audit = AuditEvent.where(ticket_id: ticket.id, event_type: "agent_action.applied").pick(:id)
        rejected_audit = AuditEvent.where(ticket_id: ticket.id, event_type: "agent_action.rejected").pick(:id)
        message_audit = AuditEvent.where(ticket_id: ticket.id, event_type: "message.received").maximum(:id)

        seqs = Message.where(ticket_id: ticket.id).order(:seq).pluck(:seq, :direction)
        expect(seqs.map(&:first)).to eq((1..seqs.size).to_a) # sem seq repetido nem buraco

        if turn.reload.status == "applied"
          # A resposta entrou antes: a saída leva o seq 2 e a mensagem do cliente, gravada depois, o 3,
          # abrindo um ciclo novo.
          expect(applied_audit).to be < message_audit
          expect(seqs).to eq([ [ 1, "inbound" ], [ 2, "outbound" ], [ 3, "inbound" ] ])
          expect(Delivery.find_by!(ticket_id: ticket.id).seq).to eq(2)
          expect(ticket).to have_attributes(latest_customer_seq: 3, first_pending_seq: 3)
        else
          # A mensagem entrou antes: o turno 1 foi superado no commit dela e a resposta, rejeitada, sem saída.
          expect(turn.status).to eq("superseded")
          expect(results.first).to have_attributes(status: :rejected, reason: "turno_superado")
          expect(rejected_audit).to be > message_audit
          expect(seqs).to eq([ [ 1, "inbound" ], [ 2, "inbound" ] ])
          expect(Delivery.where(ticket_id: ticket.id)).to be_empty
          expect(ticket).to have_attributes(latest_customer_seq: 2, first_pending_seq: 1)
        end
        turn.status
      end

      expect(outcomes).to all(be_in(%w[applied superseded]))
    end
  end

  describe "RNF-14: falha de banco no meio da aplicação" do
    it "não deixa nada parcial e sobe o erro (o consumer não confirma o offset)" do
      turn = opened_turn
      ticket_before = turn.ticket.reload.attributes
      allow(AuditEvent).to receive(:create!).and_call_original
      allow(AuditEvent).to receive(:create!).with(hash_including(event_type: "agent_action.applied"))
                                            .and_raise(ActiveRecord::ConnectionNotEstablished, "banco caiu")

      expect { apply(agent_action_for(turn)) }.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(turn.reload).to have_attributes(status: "eligible", response: nil, applied_event_id: nil)
      expect(turn.ticket.reload.attributes).to eq(ticket_before)
      expect(ProcessedEvent.count).to eq(0)
    end

    it "bloco 05: o insert do outbox da entrega falha → nem mensagem, nem entrega, nem applied" do
      turn = opened_turn
      ticket_before = turn.ticket.reload.attributes
      counts = -> { [ Message.count, Delivery.count, OutboxEvent.count, AuditEvent.count ] }
      before = counts.call
      allow(OutboxEvent).to receive(:create!).and_call_original
      allow(OutboxEvent).to receive(:create!).with(hash_including(event_type: "delivery.requested"))
                                             .and_raise(ActiveRecord::ConnectionNotEstablished, "banco caiu")
      action = agent_action_for(turn)

      expect { apply(action) }.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(counts.call).to eq(before)
      expect(turn.reload).to have_attributes(status: "eligible", response: nil, applied_event_id: nil)
      expect(turn.ticket.reload.attributes).to eq(ticket_before)
      expect(ProcessedEvent.count).to eq(0)

      allow(OutboxEvent).to receive(:create!).and_call_original
      expect(apply(action).status).to eq(:applied) # a reentrega grava o conjunto inteiro
      expect([ Message.where(direction: "outbound").count, Delivery.count ]).to eq([ 1, 1 ])
    end

    it "a reentrega depois da falha aplica normalmente (nada ficou marcado como processado)" do
      turn = opened_turn
      action = agent_action_for(turn)
      allow(DatabaseClock).to receive(:now).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect { apply(action) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      allow(DatabaseClock).to receive(:now).and_call_original

      expect(apply(action).status).to eq(:applied)
    end
  end

  describe "RN-46, 07 seção 3.4 condição 4: o relógio do banco é lido com a linha do atendimento travada" do
    it "outra conexão não consegue travar o atendimento no instante da leitura" do
      turn = opened_turn
      locked_elsewhere = nil
      allow(DatabaseClock).to receive(:now).and_wrap_original do |original|
        locked_elsewhere = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Ticket.transaction { Ticket.where(id: turn.ticket_id).lock("FOR UPDATE NOWAIT").to_a }
            false
          rescue ActiveRecord::LockWaitTimeout
            true
          end
        end.value
        original.call
      end

      expect(apply(agent_action_for(turn)).status).to eq(:applied)
      expect(locked_elsewhere).to be(true)
    end
  end
end
