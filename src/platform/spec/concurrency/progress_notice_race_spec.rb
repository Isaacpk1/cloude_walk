require "rails_helper"

# RN-57 × RF-31 (07, seções 3.2 e 3.4): o worker do aviso de progresso e a aplicação da resposta do mesmo ciclo
# ao mesmo tempo, com o Postgres de verdade, fora da transação de teste. Os dois travam a linha do atendimento:
# quem trava primeiro decide. Regra: nunca há aviso gravado depois da resposta aplicada do ciclo. Ou o aviso não
# existe (a resposta veio antes: progress.notice_discarded resposta_aplicada), ou ele tem seq menor que a resposta
# e a resposta o cancelou ainda pending.
RSpec.describe "RN-57: corrida entre o aviso de progresso e a resposta aplicada", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }

  # Relógio real: o cenário começa 16 s atrás, para o aviso estar vencido e o turno (20 s) ainda valer.
  def scenario(index)
    t0 = Time.current - 16.seconds
    ticket = travel_to(t0) { ingest("meu repasse não caiu", identity: "acc_corrida_aviso_#{index}") }.ticket
    turn = travel_to(t0 + 2.seconds) { open_turn_for(ticket) }
    item_id = Deadlines::ProgressDue.call(now: Time.current, limit: 100, ticket_ids: [ ticket.id ]).sole
    [ ticket.reload, turn, item_id ]
  end

  it "em todas as ordens: a resposta é aplicada e nenhum aviso fica depois dela nem sai ao canal" do
    outcomes = Array.new(8) do |i|
      ticket, turn, item_id = scenario(i)
      action = agent_action_for(turn)

      results = run_concurrently(threads: 2) do |n|
        n.zero? ? Turns::ProgressNotice.call(item_id) : AgentActions::Apply.call(action)
      end

      expect(results).to all(satisfy { !_1.is_a?(Exception) })
      expect(results.last.status).to eq(:applied)
      reply = Delivery.find_by!(ticket_id: ticket.id, kind: "reply")
      notice = Delivery.find_by(ticket_id: ticket.id, kind: "progress")
      expect(OutboxEvent.find(item_id).completed_at).to be_present
      expect(ticket.reload).to have_attributes(progress_due_at: nil, first_pending_seq: nil)

      if notice
        expect(notice.seq).to be < reply.seq
        expect(notice.status).to eq("cancelled")
        expect(results.first.status).to eq(:sent)
      else
        expect(results.first.status).to eq(:discarded)
        expect(AuditEvent.where(ticket_id: ticket.id, event_type: "progress.notice_discarded").sole.data)
          .to include("reason" => "resposta_aplicada")
      end
      results.first.status
    end

    expect(outcomes).to all(be_in(%i[sent discarded]))
  end

  it "dois workers do mesmo item ao mesmo tempo gravam um aviso só (repetição)" do
    ticket, _turn, item_id = scenario(99)

    results = run_concurrently(threads: 2) { Turns::ProgressNotice.call(item_id) }

    expect(results.map(&:status)).to contain_exactly(:sent, :already_done)
    expect(Delivery.where(ticket_id: ticket.id, kind: "progress").count).to eq(1)
  end
end
