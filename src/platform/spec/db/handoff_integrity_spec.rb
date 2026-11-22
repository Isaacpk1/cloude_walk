require "rails_helper"

# Base do bloco 10 (invariante 8): um resumo por handoff e uma fila de escalas ativa por marca, no banco.
RSpec.describe "Bloco 10: restrições do handoff" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:jim) { create(:brand, :jim) }
  let(:ticket) { Ticket.create!(brand: infinitepay, customer: create(:customer, brand: infinitepay), channel: "chat") }

  def summary(**attrs)
    HandoffSummary.create!({ brand: infinitepay, ticket:, from_assignment_version: 0, source: "agent", status: "available",
                             fields: { "problema" => "x" }, trace_id: "a" * 32 }.merge(attrs))
  end

  describe "RN-39, RN-40: handoff_summaries" do
    it "um resumo por handoff (atendimento e atribuição de origem)" do
      summary
      expect { summary(source: "platform") }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { summary(from_assignment_version: 1) }.not_to raise_error
    end

    it "sem resumo exige o motivo; com resumo exige os campos" do
      expect { summary(status: "missing", fields: nil, missing_reason: nil) }.to raise_error(ActiveRecord::StatementInvalid)
      expect { summary(status: "missing", fields: nil, missing_reason: "historico_vazio") }.not_to raise_error
      expect { summary(from_assignment_version: 2, fields: nil) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "RN-54: só inserção também no banco: UPDATE e DELETE são recusados" do
      record = summary
      savepoint = ->(&blk) { ActiveRecord::Base.transaction(requires_new: true, &blk) }
      expect { savepoint.call { HandoffSummary.where(id: record.id).update_all(status: "missing", missing_reason: "x") } }
        .to raise_error(ActiveRecord::StatementInvalid, /só inserção/)
      expect { savepoint.call { HandoffSummary.where(id: record.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /só inserção/)
    end

    it "invariante 6: o atendimento é da mesma marca" do
      expect { summary(brand: jim) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "origem e estado fora da lista são recusados pelo banco" do
      raw = ->(**attrs) { HandoffSummary.new(brand: infinitepay, ticket:, from_assignment_version: 9, source: "agent", status: "available",
                                             fields: {}, trace_id: "a" * 32, **attrs).save!(validate: false) }
      expect { raw.call(source: "outro") }.to raise_error(ActiveRecord::StatementInvalid)
      expect { raw.call(status: "talvez") }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "RF-42: fila de escalas" do
    let(:team) { Team.create!(brand: infinitepay, name: "Suporte N1") }

    it "no máximo uma fila de escalas ativa por marca" do
      HelpdeskQueue.create!(brand: infinitepay, team:, escalation: true)
      expect { HelpdeskQueue.create!(brand: infinitepay, team:, escalation: true) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { HelpdeskQueue.create!(brand: infinitepay, team:, escalation: true, active: false) }.not_to raise_error
    end
  end

  it "RN-33, item 6: tickets.ai_turns_count começa em zero e não fica negativo" do
    expect(ticket.ai_turns_count).to eq(0)
    expect { ticket.update_columns(ai_turns_count: -1) }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
