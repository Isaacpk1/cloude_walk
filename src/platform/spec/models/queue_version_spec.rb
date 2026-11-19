require "rails_helper"

RSpec.describe "RN-20: toda alteração em fila gera uma nova versão" do
  let(:queue) { create(:queue_record) }

  it "cria a versão 1 junto com a fila e aponta a versão atual" do
    version = queue.publish_version!(name: "Repasses", ai_first: true, created_by: create(:user))

    expect(version.version).to eq(1)
    expect(queue.reload.current_version).to eq(version)
  end

  it "uma edição cria a versão 2 e preserva a 1" do
    author = create(:user)
    v1 = queue.publish_version!(name: "Repasses", ai_first: true, created_by: author)
    v2 = queue.publish_version!(name: "Repasses e saques", ai_first: true, created_by: author)

    expect(v2.version).to eq(2)
    expect(v1.reload.name).to eq("Repasses")
    expect(queue.reload.current_version).to eq(v2)
  end

  it "não permite editar uma versão publicada" do
    v1 = queue.publish_version!(name: "Repasses", ai_first: true, created_by: create(:user))

    expect { v1.update!(name: "Outro") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "não aceita duas versões com o mesmo número na mesma fila (banco)" do
    queue.publish_version!(name: "Repasses", ai_first: true, created_by: create(:user))

    expect {
      QueueVersion.insert_all!([ { queue_id: queue.id, version: 1, name: "x", ai_first: false,
                                   sla_policy: {}, business_hours: {}, created_at: Time.current } ])
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
