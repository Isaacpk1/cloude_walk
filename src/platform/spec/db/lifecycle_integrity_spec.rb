require "rails_helper"

RSpec.describe "ADR-027, ADR-028: restrições do ciclo e das configurações" do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let!(:setup) { distribution_setup(brand) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }

  def isolated(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  it "RN-20: banco recusa alterar ou apagar versões dos tempos" do
    version = Configuration::AiPolicies.publish(brand:, attributes: { turn_deadline: 10 }, created_by: boss).record
    expect { isolated { AiPolicyVersion.where(id: version.id).update_all(version: 3) } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { isolated { AiPolicyVersion.where(id: version.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "ADR-020: banco recusa JSON null em um tempo obrigatório" do
    settings = Turns::Policy::DEFAULT.to_snapshot.except("version").merge("turn_deadline" => nil)
    expect do
      isolated { AiPolicyVersion.create!(brand:, version: 1, settings:, created_by: boss, created_at: Time.current) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "RNF-24: banco recusa resumo associado a outra marca e conserva resumos imutáveis" do
    ticket = ingest.ticket
    values = { ticket:, assignment_version: 0, resolved_at: Time.current, body: "Resumo", created_at: Time.current }
    expect { isolated { TicketSummary.create!(brand: jim, **values) } }.to raise_error(ActiveRecord::InvalidForeignKey)
    summary = TicketSummary.create!(brand:, **values)
    expect { isolated { TicketSummary.where(id: summary.id).update_all(body: "alterado") } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { isolated { TicketSummary.where(id: summary.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "RN-08: uma reabertura humana volta à fila e não reserva uma vaga" do
    analyst = analyst_in(setup[:team])
    ticket = case_with(analyst, brand:, queue: setup[:queue], identity: "acc_human")
    Human::Resolve.call(ticket_id: ticket.id, brand_id: brand.id, user: analyst, reason: "problema_resolvido")
    received = ingest("continua com erro", identity: "acc_human")
    expect(received.ticket.id).to eq(ticket.id)
    expect(ticket.reload).to have_attributes(state: "aguardando_humano", assignee_id: nil)
    expect(analyst.reload.active_count).to eq(0)
  end
end
