require "rails_helper"

# Pedido de humano na ingestão × resposta da IA do turno em andamento, com o Postgres de verdade, fora da transação
# de teste (RN-34, RN-38, RN-56, invariante 4; 07, seção 3.4 e seção 6, "O cliente pede humano com uma saída da IA
# pendente"). A ordem é decidida sem sleep, como no timeout_race_spec: uma conexão segura a trava do atendimento, as
# operações entram na fila da trava na ordem pedida (pg_stat_activity) e a trava é solta.
RSpec.describe "RN-34: pedido de humano concorrendo com a resposta da IA", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:queue) { default_queue(infinitepay) }
  let(:t0) { Time.current.utc.change(usec: 0) }
  let(:identity) { "acc_infinitepay_pedido_humano" }

  def hold_ticket_lock(ticket_id)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Ticket.where(id: ticket_id).lock.to_a
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    [ holder, release ]
  end

  def start_blocked(&operation)
    pid = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value("SELECT pg_backend_pid()")
        operation.call
      end
    end
    wait_for_lock(pid.pop, worker)
    worker
  end

  def wait_for_lock(pid, worker)
    limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until ActiveRecord::Base.connection.select_value(
      "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
    ) == "Lock"
      raise "a operação terminou sem esperar a trava: #{worker.value.inspect}" unless worker.alive?
      raise "a operação não chegou à trava em 10 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

      Thread.pass
    end
  end

  def race(order, ticket_id, operations)
    holder, release = hold_ticket_lock(ticket_id)
    threads = order.map { |name| [ name, start_blocked(&operations.fetch(name)) ] }
    release << true
    holder.join
    threads.to_h { |name, thread| [ name, thread.value ] }
  end

  def open_turn_at_t0(identity: self.identity)
    travel_to(t0, with_usec: true) { ingest("meu repasse não caiu", identity:) }
    travel_to(t0 + 1.5.seconds, with_usec: true) do
      Turns::Open.call(Deadlines::DispatchDue.call(now: Time.current, limit: 10).sole).turn
    end
  end

  def operations(turn, identity: self.identity)
    reply = agent_action_for(turn)
    { apply: -> { AgentActions::Apply.call(reply, traceparent: AgentActionHelpers::TRACEPARENT) },
      ask: -> { ingest("quero falar com um atendente", identity:) } }
  end

  def run(order)
    turn = open_turn_at_t0
    results = travel_to(t0 + 2.seconds, with_usec: true) { race(order, turn.ticket_id, operations(turn)) }
    raise results.values.find { _1.is_a?(Exception) } if results.values.any?(Exception)

    [ turn.reload, results ]
  end

  def escalate(ticket)
    Handoff::Escalate.call(handoff_items(ticket).sole.id)
    ticket.reload
  end

  def bot_deliveries(ticket) = Delivery.where(ticket_id: ticket.id, kind: %w[reply resolution progress])
  def applied_audit(ticket) = audits(ticket, "agent_action.applied").pick(:id)
  def human_message(ticket) = Message.find_by!(ticket_id: ticket.id, body: "quero falar com um atendente")

  describe "RN-34, RN-56: o pedido pega a trava primeiro" do
    it "o turno expira pelo pedido; a resposta é rejeitada (handoff_pedido) e nada da IA é gravado para o cliente" do
      turn, results = run(%i[ask apply])

      expect(results[:ask]).to be_created
      expect(results[:apply]).to have_attributes(status: :rejected, reason: "handoff_pedido")
      expect(turn.status).to eq("expired")
      expect(applied_audit(turn.ticket)).to be_nil
      expect(bot_deliveries(turn.ticket)).to be_empty

      ticket = escalate(turn.ticket)
      expect(ticket).to have_attributes(state: "aguardando_humano", assignment_version: 1)
      expect(Message.where(ticket_id: ticket.id, direction: "outbound", author_type: "bot")).to be_empty
    end
  end

  describe "RN-34, RN-38: a resposta pega a trava primeiro" do
    it "a resposta cobre só a mensagem 1; o pedido (seq 3) escala, e a resposta que não saiu é cancelada" do
      turn, results = run(%i[apply ask])

      expect(results[:apply].status).to eq(:applied)
      expect(results[:ask]).to be_created
      expect(turn.status).to eq("applied")
      # A resposta foi aplicada antes de o pedido existir: seq 2 é a saída, seq 3 o pedido.
      expect(applied_audit(turn.ticket)).to be < audits(turn.ticket, "customer.human_requested").sole.id
      expect(human_message(turn.ticket).seq).to eq(3)
      expect(handoff_items(turn.ticket).sole.payload).to include("reason" => "pedido_do_cliente", "turn" => nil)

      ticket = escalate(turn.ticket)
      expect(ticket.state).to eq("aguardando_humano")
      # RN-38: a resposta ainda na fila não chega ao cliente depois do pedido.
      expect(bot_deliveries(ticket).pluck(:status)).to eq([ "cancelled" ])
    end
  end

  describe "invariante 4: sem ordem combinada, várias rodadas" do
    it "nunca uma resposta aplicada depois do pedido, e nunca uma entrega da IA viva depois do Escalate" do
      outcomes = Array.new(6) do |round|
        id = "acc_infinitepay_pedido_corrida_#{round}"
        turn = open_turn_at_t0(identity: id)
        ops = operations(turn, identity: id)

        results = travel_to(t0 + 2.seconds, with_usec: true) do
          run_concurrently(threads: 2) { |i| i.zero? ? ops[:apply].call : ops[:ask].call }
        end
        raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

        ticket = turn.ticket
        applied = applied_audit(ticket)
        requested = audits(ticket, "customer.human_requested").sole
        expect(requested.data["outcome"]).to eq("handoff_pedido")
        expect(applied).to be < requested.id if applied
        expect(turn.reload.status).to be_in(%w[applied expired])

        seqs = Message.where(ticket_id: ticket.id).order(:seq).pluck(:seq)
        expect(seqs).to eq((1..seqs.size).to_a)

        escalate(ticket)
        expect(ticket.state).to eq("aguardando_humano")
        expect(bot_deliveries(ticket).where.not(status: "cancelled")).to be_empty
        turn.status
      end

      expect(outcomes).to all(be_in(%w[applied expired]))
    end
  end

  describe "RF-39 a RF-42 (aceite): o mesmo pedido em duas mensagens simultâneas" do
    it "um único handoff.requested; o outro fica handoff_ja_pedido" do
      turn = open_turn_at_t0

      results = travel_to(t0 + 2.seconds, with_usec: true) do
        run_concurrently(threads: 2) { |i| ingest("quero falar com um atendente #{i}", identity:) }
      end
      raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

      expect(handoff_items(turn.ticket).count).to eq(1)
      expect(audits(turn.ticket, "customer.human_requested").map { _1.data["outcome"] })
        .to contain_exactly("handoff_pedido", "handoff_ja_pedido")
      expect(results.filter_map(&:handoff_event_id)).to eq([ handoff_items(turn.ticket).sole.id ])
    end

    it "o mesmo webhook entregue duas vezes ao mesmo tempo: uma mensagem, um pedido, uma auditoria" do
      open_turn_at_t0
      payload = normalized_message(text: "quero falar com um atendente", identity:, external_id: "chat_msg_dup_humano")

      results = travel_to(t0 + 2.seconds, with_usec: true) do
        run_concurrently(threads: 3) { Ingestion::Receive.call(payload, provider_payload: {}) }
      end
      raise results.find { _1.is_a?(Exception) } if results.any?(Exception)

      expect(results.map(&:status).tally).to eq(created: 1, duplicate: 2)
      ticket = results.first.ticket
      expect(handoff_items(ticket).count).to eq(1)
      expect(audits(ticket, "customer.human_requested").count).to eq(1)
    end
  end
end
