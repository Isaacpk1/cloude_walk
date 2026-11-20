require "rails_helper"

# Invariante 8: as regras do turno e da publicação vivem no banco (07, seção 4).
RSpec.describe "Invariante 8: restrições dos turnos e do outbox de publicação" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:jim) { create(:brand, :jim) }
  let(:customer) { create(:customer, brand: infinitepay) }
  let(:ticket) { Ticket.create!(brand: infinitepay, customer:, channel: "chat") }
  let(:now) { Time.current }

  def insert_turn(**attrs)
    row = { brand_id: infinitepay.id, ticket_id: ticket.id, turn: 1, context_until_seq: 1, assignment_version: 0,
            context: {}, event_id: SecureRandom.uuid, status: "eligible", deadline_at: now + 30,
            created_at: now, updated_at: now }.merge(attrs)
    AiTurn.insert_all!([ row ])
  end

  it "RN-56: um turno com o mesmo número por atendimento" do
    insert_turn(turn: 1)

    expect { insert_turn(turn: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "aceita o turno seguinte do mesmo atendimento" do
    insert_turn(turn: 1)

    expect { insert_turn(turn: 2) }.not_to raise_error
  end

  it "RN-47: o event_id do turno é único" do
    event_id = SecureRandom.uuid
    insert_turn(turn: 1, event_id:)

    expect { insert_turn(turn: 2, event_id:) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "só aceita os estados do 07, seção 3.4" do
    expect { insert_turn(status: "aplicado") }.to raise_error(ActiveRecord::StatementInvalid, /ai_turns_status_check/)
  end

  it "ADR-014: o turno é da marca do atendimento (marca errada)" do
    expect { insert_turn(brand_id: jim.id) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "turno e número de contexto começam em 1" do
    expect { insert_turn(turn: 0) }.to raise_error(ActiveRecord::StatementInvalid, /ai_turns_turn_check/)
  end

  it "RN-43: o outbox conta as tentativas a partir de zero" do
    item = OutboxEvent.create!(brand: infinitepay, ticket:, event_type: "agent.event", payload: {}, trace_id: "t",
                               next_attempt_at: now)

    expect(item.reload.attempts).to eq(0)
    expect { item.update_columns(attempts: -1) }.to raise_error(ActiveRecord::StatementInvalid, /outbox_events_attempts_check/)
  end
end
