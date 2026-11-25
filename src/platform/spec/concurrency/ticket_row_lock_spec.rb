require "rails_helper"

# Medido no pico (bench/results/2026-11-24-pico): `SELECT tickets ... FOR UPDATE` somou ~1000 s de espera e o
# `FOR KEY SHARE` das chaves estrangeiras (gravar audit_events, messages, deliveries, outbox_events) outros ~200 s.
# FOR UPDATE bloqueia quem só grava linhas filhas; FOR NO KEY UPDATE não, e continua exclusivo entre quem altera o
# atendimento. O id do atendimento nunca muda, então a trava mais fraca basta (ADR-031).
RSpec.describe "ADR-031: trava da linha do atendimento (FOR NO KEY UPDATE)", :concurrency do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:ticket) { ingest("meu repasse não caiu").ticket }

  # Segura a trava numa conexão própria até `release` e devolve a thread.
  def hold_lock(ticket)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticket.transaction do
          Ticket.lock(Ticket::ROW_LOCK).find_by!(id: ticket.id, brand_id: ticket.brand_id)
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    [ holder, release ]
  end

  it "usa FOR NO KEY UPDATE na constante compartilhada" do
    expect(Ticket::ROW_LOCK).to eq("FOR NO KEY UPDATE")
    expect(Ticket.lock(Ticket::ROW_LOCK).where(id: 1).to_sql).to end_with("FOR NO KEY UPDATE")
  end

  it "não bloqueia a gravação de uma linha filha (FK) enquanto outra conexão segura o atendimento" do
    holder, release = hold_lock(ticket)
    wrote = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        AuditEvent.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
          AuditEvent.create!(brand_id: ticket.brand_id, ticket:, actor_type: "system", event_type: "teste.fk",
                             trace_id: "c" * 32, data: {})
        end
        true
      rescue ActiveRecord::LockWaitTimeout
        false
      end
    end.value
    release << true
    holder.join

    expect(wrote).to be(true)
  end

  it "continua exclusiva entre quem trava o atendimento para alterá-lo" do
    holder, release = hold_lock(ticket)
    blocked = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticket.transaction { Ticket.where(id: ticket.id).lock("#{Ticket::ROW_LOCK} NOWAIT").to_a }
        false
      rescue ActiveRecord::LockWaitTimeout
        true
      end
    end.value
    release << true
    holder.join

    expect(blocked).to be(true)
  end
end
