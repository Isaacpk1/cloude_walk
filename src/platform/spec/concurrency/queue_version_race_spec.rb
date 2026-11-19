require "rails_helper"

RSpec.describe "RN-20: oito edições simultâneas da mesma fila", :concurrency do
  it "gera versões sequenciais sem pular nem repetir" do
    queue = create(:queue_record)
    author = create(:user)

    results = run_concurrently(threads: 8) do |i|
      HelpdeskQueue.find(queue.id).publish_version!(name: "Edição #{i}", ai_first: true, created_by: author)
    end

    expect(results).to all(be_a(QueueVersion))
    expect(queue.versions.pluck(:version).sort).to eq((1..8).to_a)
    expect(queue.reload.current_version.version).to eq(8)
  end
end
