# Formato de leitura de uma execução de eval (eval_runs; ADR-023). A tela só conhece esta representação.
# `checks` vêm no formato combinado { name, expected, observed, ok, evidence: { turn, seq } }; turn e seq só
# viram link quando são inteiros positivos (o conteúdo é gravado pelo executor, mas a tela não confia nele).
class EvalView < Data.define(:id, :scenario, :status, :agent_model, :agent_version, :config_hash, :brand_slug, :brand_name,
                             :ticket_id, :trace_id, :started_at, :finished_at, :expected, :observed, :checks, :error)
  STATUS_LABELS = { "passed" => "Passou", "failed" => "Falhou", "error" => "Erro" }.freeze

  Check = Data.define(:name, :expected, :observed, :ok, :turn, :seq) do
    def failed? = !ok
  end

  def self.from(run)
    new(id: run.id, scenario: run.scenario, status: run.status, agent_model: run.agent_model, agent_version: run.agent_version,
        config_hash: run.config_hash, brand_slug: run.brand.slug, brand_name: run.brand.name, ticket_id: run.ticket_id,
        trace_id: run.trace_id, started_at: run.started_at, finished_at: run.finished_at, expected: run.expected,
        observed: run.observed, checks: Array(run.checks).map { check(_1) }.freeze, error: run.error)
  end

  def self.check(item)
    item = item.is_a?(Hash) ? item : {}
    evidence = item["evidence"].is_a?(Hash) ? item["evidence"] : {}
    Check.new(name: item["name"].to_s, expected: item["expected"], observed: item["observed"], ok: item["ok"] == true,
              turn: anchor_number(evidence["turn"]), seq: anchor_number(evidence["seq"]))
  end

  def self.anchor_number(value) = value.is_a?(Integer) && value.positive? ? value : nil

  def status_label = STATUS_LABELS.fetch(status, status)
  def short_config_hash = config_hash&.delete_prefix("sha256:")&.first(12)
  def duration_ms = finished_at && TimelineView::Event.ms_between(started_at, finished_at)
  def error? = status == "error"
end
