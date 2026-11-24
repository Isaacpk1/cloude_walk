require "rails_helper"

# E3: publicação e entrada simultâneas em conexões reais; cada decisão usa uma versão inteira.
RSpec.describe "RF-16, RF-18, RN-18: E3 com atendimentos chegando durante a edição", :concurrency do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:setup) { triage_setup(brand, ai_first: false) }
  let!(:destination) { create(:routing_queue, team: setup[:team], name: "Repasses", ai_first: false) }
  let!(:author) { analyst_in(setup[:team], role: "supervisor") }

  def publish(rules)
    RoutingRuleset.publish!(brand:, rules:, default_queue: setup[:default], created_by: author)
  end

  def receive_case(identity)
    ticket = ingest("meu repasse não caiu", brand: brand.slug, identity:).ticket
    run_triage(ticket)
    ticket.reload
  end

  it "cada caso guarda versão e destino coerentes; o cache aquecido vê a edição e os antigos não mudam" do
    publish(ruleset_json)
    first = receive_case("acc_before_edit") # aquece o cache da versão 1
    rules = ruleset_json([ "Repasses", destination, [ [ %w[category eq repasses] ] ] ])

    outcomes = run_concurrently(threads: 7) do |index|
      index.zero? ? publish(rules) : receive_case("acc_during_edit_#{index}")
    end
    expect(outcomes).to all(satisfy { !_1.is_a?(Exception) })
    after = receive_case("acc_after_edit")

    expect(first.reload).to have_attributes(queue_id: setup[:default].id, ruleset_version: 1)
    expect(after).to have_attributes(queue_id: destination.id, ruleset_version: 2)
    ([ first, after ] + outcomes.grep(Ticket)).each do |ticket|
      expected_queue = ticket.ruleset_version == 1 ? setup[:default] : destination
      expect(ticket.ruleset_version).to be_in([ 1, 2 ])
      expect(ticket.queue_id).to eq(expected_queue.id)
      decision = AuditEvent.where(brand:, ticket:, event_type: "routing.decided").sole
      expect(decision.data).to include("queue_id" => expected_queue.id, "ruleset_version" => ticket.ruleset_version)
    end
    expect(Configuration::Queues.destroy(brand:, queue_id: destination.id, created_by: author).ok).to be(false)
    expect(destination.reload.archived_at).to be_nil
  end
end
