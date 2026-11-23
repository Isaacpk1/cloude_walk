require "rails_helper"

# Bloco 19, RNF-14, RNF-30: o script de reconciliação do experimento (bench/analysis/reconcile.rb) conta perdas,
# turnos e latência só das mensagens da execução pedida.
RSpec.describe "Experimento: bench/analysis/reconcile.rb" do
  let!(:brand) { create(:brand, :infinitepay) }
  let!(:account) { create(:provider_account, brand:, slug: "infinitepay-chat-mock") }
  let(:script) { Rails.root.join("../../bench/analysis/reconcile.rb").to_s }
  let(:start) { Time.zone.parse("2026-11-20T13:40:00Z") }

  around { |example| travel_to(start) { example.run } }

  def reconcile(run_id, k6: nil)
    file = Tempfile.new([ "k6", ".json" ])
    file.write(JSON.generate(k6)) if k6
    file.close
    stub_const("ARGV", [ run_id, (file.path if k6) ].compact)
    JSON.parse(capture_stdout { load script })
  ensure
    file&.unlink
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def k6_summary(accepted:) = { "profile" => "smoke", "mode" => "independent", "seed" => 42,
                                "metrics" => { "helpdesk_accepted" => { "values" => { "count" => accepted } },
                                               "helpdesk_duplicate" => { "values" => { "count" => 0 } },
                                               "helpdesk_rejected" => { "values" => { "count" => 0 } } } }

  it "RNF-14: sem perda quando todo 202 do k6 está no banco" do
    customer_message("oi", external_id: "bench_r1_1")
    customer_message("de novo", external_id: "bench_r1_2") # mesmo cliente: segue no mesmo atendimento

    report = reconcile("r1", k6: k6_summary(accepted: 2))

    expect(report).to include("stored_messages" => 2, "lost_messages" => 0, "conversations" => 1)
  end

  it "RNF-14: aponta a perda quando o k6 confirmou mais do que o banco tem" do
    customer_message("oi", external_id: "bench_r2_1")

    expect(reconcile("r2", k6: k6_summary(accepted: 3))).to include("stored_messages" => 1, "lost_messages" => 2)
  end

  it "não conta mensagens de outra execução" do
    customer_message("oi", external_id: "bench_outra_1")

    expect(reconcile("r3", k6: k6_summary(accepted: 0))).to include("stored_messages" => 0, "lost_messages" => 0)
  end

  it "mede a latência da resposta entregue desde a mensagem do cliente" do
    inbound = customer_message("oi", external_id: "bench_r4_1")
    delivery = requested_delivery(inbound.ticket)
    delivery.update_columns(status: "delivered", provider_message_id: "chat_out_1", delivered_at: start + 2.5.seconds)

    report = reconcile("r4")

    expect(report["reply_delivered_after_ms"]).to include("count" => 1, "p50" => 2500.0)
    expect(report["lost_messages"]).to be_nil
  end
end
