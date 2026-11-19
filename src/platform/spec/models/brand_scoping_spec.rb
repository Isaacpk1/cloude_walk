require "rails_helper"

RSpec.describe "RF-58: tudo pertence a uma marca" do
  it "exige marca em equipe, cliente e fila" do
    expect { Team.create!(name: "Sem marca") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { Customer.create!(display_name: "Sem marca") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { HelpdeskQueue.create!(team: create(:team)) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "garante a marca também no banco, não só no Ruby" do
    expect {
      Customer.insert_all!([ { display_name: "x", created_at: Time.current, updated_at: Time.current } ])
    }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "recusa fila de uma marca ligada a equipe de outra (marca errada)" do
    infinitepay = create(:brand, :infinitepay)
    team_jim = create(:team, brand: create(:brand, :jim))

    queue = HelpdeskQueue.new(brand: infinitepay, team: team_jim)

    expect(queue).not_to be_valid
    expect(queue.errors[:team]).to be_present
  end
end
