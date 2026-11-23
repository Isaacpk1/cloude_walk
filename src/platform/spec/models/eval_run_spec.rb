require "rails_helper"

RSpec.describe EvalRun, "ADR-023: execução de eval gravada só por inserção" do
  let(:brand) { create(:brand, :infinitepay) }

  def build_run(**attrs)
    described_class.new(scenario: "corrida-3s", status: "passed", agent_model: "eval-fixture", agent_version: "1",
                        brand:, started_at: Time.current, finished_at: Time.current, **attrs)
  end

  it "grava esperado, observado e checagens" do
    run = build_run(expected: { "turns" => 2 }, observed: { "turns" => 2 },
                    checks: [ { "name" => "turno 1 superado", "ok" => true } ])
    run.save!

    expect(run.reload).to have_attributes(status: "passed", checks: [ { "name" => "turno 1 superado", "ok" => true } ])
  end

  it "o banco recusa status fora da lista e checagens que não são lista" do
    savepoint = ->(&block) { ActiveRecord::Base.transaction(requires_new: true, &block) }

    expect { savepoint.call { build_run(status: "talvez").save!(validate: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /eval_runs_status_check/)
    expect { savepoint.call { build_run(checks: {}).save!(validate: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /eval_runs_checks_check/)
  end

  it "uma execução gravada não muda nem some (só inserção)" do
    run = build_run.tap(&:save!)

    expect { run.update!(status: "failed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { described_class.where(id: run.id).update_all(status: "failed") }
      .to raise_error(ActiveRecord::StatementInvalid, /só de inserção/)
  end
end
