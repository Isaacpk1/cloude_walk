# E2, E3, E4, E6: relatório reproduzível dos cenários dos blocos 17 e 18.
# Execute pelo make validate-operation. Nunca executa em development ou production.
require "json"
require "fileutils"
require "digest"
require "time"

abort "RAILS_ENV precisa ser test" unless ENV["RAILS_ENV"] == "test"
abort "use um banco de teste separado (TEST_ENV_NUMBER=_operation)" unless ENV["TEST_ENV_NUMBER"] == "_operation"

output = ARGV.fetch(0)
FileUtils.mkdir_p(output)
groups = {
  "E2" => %w[spec/concurrency/recovery_fault_injection_spec.rb spec/concurrency/scheduler_race_spec.rb
             spec/concurrency/timeout_race_spec.rb spec/services/deadlines/timeout_ready_spec.rb
             spec/requests/recovery_panel_spec.rb],
  "E3" => %w[spec/concurrency/operation_routing_spec.rb spec/concurrency/routing_ruleset_race_spec.rb
             spec/concurrency/queue_version_race_spec.rb spec/services/configuration/queues_spec.rb
             spec/requests/configuration_spec.rb spec/requests/routing_ready_spec.rb spec/system/operation_configuration_spec.rb
             spec/read_models/operational_overview_spec.rb spec/requests/operational_overview_spec.rb],
  "E4" => %w[spec/concurrency/slot_race_spec.rb spec/concurrency/return_to_queue_race_spec.rb
             spec/concurrency/commit_order_race_spec.rb spec/concurrency/reply_before_broker_ack_spec.rb
             spec/requests/handoff_transfer_end_to_end_spec.rb spec/requests/handoff_panel_spec.rb
             spec/requests/human_queue_spec.rb spec/services/agent_actions/race_3s_spec.rb
             spec/models/audit_event_broadcast_spec.rb],
  "E6" => %w[spec/requests/brand_scope_spec.rb spec/requests/webhooks_spec.rb
             spec/requests/webhook_logging_spec.rb spec/channels/connection_spec.rb
             spec/db/brand_integrity_spec.rb spec/models/brand_scoping_spec.rb]
}
raw = File.join(output, "rspec.json")
started_at = Time.now.utc.iso8601
success = system("bundle", "exec", "rspec", *groups.values.flatten.uniq, "--seed", "42", "--format", "progress", "--format", "json", "--out", raw)
data = JSON.parse(File.read(raw))
report = groups.transform_values do |files|
  examples = data.fetch("examples").select { files.include?(_1.fetch("file_path").delete_prefix("./")) }
  { "status" => examples.any? && examples.all? { _1["status"] == "passed" } ? "passed" : "incomplete",
    "examples" => examples.map { _1.slice("id", "full_description", "status", "file_path", "line_number", "exception", "pending_message") } }
end
source_digest = Digest::SHA256.new
Dir.glob("{app,config,spec,db}/**/*").select { File.file?(_1) }.sort.each do |path|
  source_digest.update(path).update(File.binread(path))
end
result = { "started_at" => started_at, "finished_at" => Time.now.utc.iso8601,
           "base_revision" => ENV.fetch("VALIDATION_REVISION", "não informada"), "source_sha256" => source_digest.hexdigest,
           "ruby" => RUBY_DESCRIPTION, "database" => "helpdesk_test_operation", "seed" => 42,
           "method" => "RSpec, Postgres real; falhas HTTP e perda de jobs injetadas; tempo controlado; ActionCable test adapter",
           "limits" => [ "Não mede percentis no Compose nem substitui E1/E5.",
                         "Não derruba os serviços de desenvolvimento; falhas são injetadas nos testes.",
                         "Inscrições e broadcasts conferidos no servidor; roteiro visual em bench/validation/README.md." ],
           "summary" => data.fetch("summary"), "experiments" => report }
File.write(File.join(output, "summary.json"), JSON.pretty_generate(result) + "\n")
exit(success && report.values.all? { _1["status"] == "passed" } ? 0 : 1)
