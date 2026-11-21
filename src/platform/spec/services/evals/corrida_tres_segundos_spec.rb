require "rails_helper"
require "rake"

# ADR-023, ROADMAP bloco 07 (frontend: "o primeiro eval do cenário dos 3 s") e bloco 16 ("um cenário correto e
# outro com falha intencional geram resultados diferentes"). O executor percorre o caminho real (ingestão,
# scheduler, abertura do turno e aplicação da ação) com o relógio controlado: o sleeper só anda o relógio, sem
# sleep. O AgentActions::Apply confere o prazo pelo relógio do banco; aqui ele acompanha o travel_to.
RSpec.describe "RN-56, ADR-023: eval corrida-3s" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let(:clock) { -> { Time.current } }
  let(:sleeper) { ->(seconds) { travel_to(Time.current + seconds, with_usec: true) if seconds.positive? } }

  let(:check_names) do
    [ "turno 1 cobre só a mensagem 1", "mensagem 2 supera o turno 1 no commit",
      "resposta do turno 1 rejeitada como turno_superado", "nenhuma saída do turno 1",
      "turno 2 cobre as mensagens 1 e 2", "resposta do turno 2 aplicada", "uma única saída ao cliente" ]
  end

  before do
    travel_to(t0, with_usec: true)
    allow(DatabaseClock).to receive(:now) { Time.current }
  end

  def run_eval(brand: infinitepay) = Evals::Runner.call("corrida-3s", brand:, clock:, sleeper:)
  def check(run, name) = run.checks.find { _1["name"] == name }
  def failing(run) = run.checks.reject { _1["ok"] }.map { _1["name"] }

  describe "Evals::Catalog" do
    it "lista o cenário corrida-3s com título e descrição e devolve a classe dele" do
      expect(Evals::Catalog.scenarios).to contain_exactly(
        a_hash_including(name: "corrida-3s", title: a_string_including("3 s"), description: a_kind_of(String))
      )
      expect(Evals::Catalog.fetch("corrida-3s")).to eq(Evals::Scenarios::CorridaTresSegundos)
    end

    it "nome desconhecido é erro explícito" do
      expect { Evals::Catalog.fetch("corrida-9s") }.to raise_error(Evals::Catalog::UnknownScenario, /corrida-9s/)
      expect { Evals::Runner.call("corrida-9s", brand: infinitepay, clock:, sleeper:) }
        .to raise_error(Evals::Catalog::UnknownScenario)
      expect(EvalRun.count).to eq(0)
    end
  end

  describe "execução correta" do
    it "sai passed com as 7 checagens ok, na ordem, e grava uma linha só" do
      run = run_eval

      expect(EvalRun.count).to eq(1)
      expect(run).to be_persisted
      expect(run).to have_attributes(scenario: "corrida-3s", status: "passed", error: nil, brand_id: infinitepay.id,
                                     agent_model: "eval-fixture",
                                     agent_version: Evals::Scenarios::CorridaTresSegundos::FIXTURE_VERSION,
                                     config_hash: Evals::Scenarios::CorridaTresSegundos.config_hash)
      expect(run.checks.map { _1["name"] }).to eq(check_names)
      expect(run.checks).to all(include("ok" => true))
      expect(run.started_at).to eq(t0)
      expect(run.finished_at).to be >= t0 + 4.5.seconds
    end

    it "a evidência: turno 1 superseded, turno 2 applied com [1, 2], uma saída, a recusa do turno 1" do
      run = run_eval
      observed = run.observed

      expect(observed["turns"]).to eq([
        { "turn" => 1, "status" => "superseded", "context_until_seq" => 1, "pending_seqs" => [ 1 ] },
        { "turn" => 2, "status" => "applied", "context_until_seq" => 2, "pending_seqs" => [ 1, 2 ] }
      ])
      expect(observed["outbound_seqs"]).to eq([ 3 ])
      expect(observed["rejections"]).to eq([ { "turn" => 1, "reason" => "turno_superado" } ])
      expect(check(run, "mensagem 2 supera o turno 1 no commit"))
        .to include("expected" => "superseded", "observed" => "superseded", "evidence" => { "turn" => 1, "seq" => 2 })
      expect(check(run, "uma única saída ao cliente")).to include("evidence" => { "turn" => 2, "seq" => 3 })
    end

    it "os passos acontecem nos horários do cenário (t_ms relativo à mensagem 1)" do
      steps = run_eval.observed["steps"].to_h { [ _1["step"], _1["t_ms"] ] }

      expect(steps).to eq("mensagem 1" => 0, "turno 1 aberto" => 1500, "mensagem 2" => 3000,
                          "resposta do turno 1" => 3500, "turno 2 aberto" => 4000, "resposta do turno 2" => 4500)
    end

    it "o atendimento é sintético, novo, da marca, com cliente verificado e conta eval_ própria; trace da mensagem 1" do
      run = run_eval
      ticket = run.ticket

      expect(ticket.brand_id).to eq(infinitepay.id)
      expect(ticket.customer).to have_attributes(verified: true, brand_id: infinitepay.id)
      identity = ticket.customer.identities.sole
      expect(identity).to have_attributes(channel: "chat", external_id: a_string_starting_with("eval_"))
      expect(run.trace_id).to eq(ticket.messages.find_by!(seq: 1).trace_id).and match(/\A\h{32}\z/)
      expect(run.expected).to include("outbound_count" => 1)
    end

    it "as ações do gabarito ficam auditadas com o modelo eval-fixture e a versão do gabarito" do
      ticket = run_eval.ticket

      audits = AuditEvent.where(ticket_id: ticket.id, event_type: %w[agent_action.applied agent_action.rejected])
      expect(audits.pluck(:event_type, :agent_model, :agent_version)).to contain_exactly(
        [ "agent_action.rejected", "eval-fixture", Evals::Scenarios::CorridaTresSegundos::FIXTURE_VERSION ],
        [ "agent_action.applied", "eval-fixture", Evals::Scenarios::CorridaTresSegundos::FIXTURE_VERSION ]
      )
    end

    it "o config_hash é o SHA-256 do gabarito" do
      scenario = Evals::Scenarios::CorridaTresSegundos
      digest = Digest::SHA256.hexdigest(JSON.generate(scenario::FIXTURE))

      expect(scenario.config_hash).to eq("sha256:#{digest}")
    end

    it "loga em JSON com trace_id, sem o texto das mensagens (RN-51)" do
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |m, msg| lines << msg; m.call(msg) }

      run = run_eval

      eval_lines = lines.grep(String).select { _1.start_with?("{") }.map { JSON.parse(_1) }
                        .select { _1["event"].to_s.start_with?("eval.") }
      expect(eval_lines.map { _1["event"] }).to include("eval.step", "eval.finished")
      expect(eval_lines).to all(include("trace_id" => run.trace_id))
      texts = Evals::Scenarios::CorridaTresSegundos::FIXTURE.dig("messages").map { _1["text"] }
      expect(lines.grep(String).join).not_to include(*texts)
    end
  end

  describe "eval que pega defeito (falha intencional)" do
    it "se a ingestão não superar o turno 1, sai failed na checagem da mensagem 2, com o observado" do
      allow_any_instance_of(Ingestion::Receive).to receive(:supersede_turns)

      run = run_eval

      expect(run.status).to eq("failed")
      expect(failing(run)).to eq([ "mensagem 2 supera o turno 1 no commit" ])
      expect(check(run, "mensagem 2 supera o turno 1 no commit")).to include("expected" => "superseded", "observed" => "eligible",
                                                                               "ok" => false)
    end

    it "só o Apply sem as condições ainda recusa: a atualização condicional eligible → applied segura (invariante 8)" do
      allow_any_instance_of(AgentActions::Apply).to receive(:rejection_reason).and_return(nil)

      run = run_eval

      expect(failing(run)).to eq([ "resposta do turno 1 rejeitada como turno_superado" ])
      expect(check(run, "resposta do turno 1 rejeitada como turno_superado"))
        .to include("observed" => { "status" => "rejected", "reason" => "turno_nao_elegivel" })
      expect(check(run, "nenhuma saída do turno 1")).to include("ok" => true)
    end

    it "sem a RN-56 (ingestão não supera e o Apply aceita o turno 1), sai failed com a saída do turno 1 como evidência" do
      allow_any_instance_of(Ingestion::Receive).to receive(:supersede_turns)
      allow_any_instance_of(AgentActions::Apply).to receive(:rejection_reason).and_return(nil)

      run = run_eval

      expect(run.status).to eq("failed")
      expect(failing(run)).to include("mensagem 2 supera o turno 1 no commit",
                                      "resposta do turno 1 rejeitada como turno_superado", "nenhuma saída do turno 1",
                                      "turno 2 cobre as mensagens 1 e 2", "resposta do turno 2 aplicada")
      expect(check(run, "resposta do turno 1 rejeitada como turno_superado"))
        .to include("observed" => { "status" => "applied", "reason" => nil })
      expect(check(run, "nenhuma saída do turno 1")).to include("observed" => [ 3 ], "ok" => false)
    end

    it "certo e errado geram resultados diferentes" do
      right = run_eval
      allow_any_instance_of(Ingestion::Receive).to receive(:supersede_turns)
      wrong = run_eval

      expect([ right.status, wrong.status ]).to eq(%w[passed failed])
    end
  end

  describe "erro no meio" do
    it "grava error com o observado até ali e a mensagem do erro" do
      calls = 0
      allow(Turns::Open).to receive(:call).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::ConnectionNotEstablished, "banco fora" if calls == 2

        original.call(*args)
      end

      run = run_eval

      expect(EvalRun.count).to eq(1)
      expect(run).to have_attributes(status: "error", error: a_string_including("banco fora"))
      expect(run.observed["turns"].map { _1["turn"] }).to eq([ 1 ])
      expect(run.observed["rejections"]).to eq([ { "turn" => 1, "reason" => "turno_superado" } ])
      expect(run.ticket).to be_present
      expect(run.finished_at).to be_present
    end
  end

  describe "repetição e concorrência com o scheduler" do
    it "dois runs seguidos não se misturam: atendimentos, clientes e contas diferentes" do
      first = run_eval
      second = run_eval

      expect([ first.status, second.status ]).to eq(%w[passed passed])
      expect(first.ticket_id).not_to eq(second.ticket_id)
      expect(first.ticket.customer_id).not_to eq(second.ticket.customer_id)
      accounts = [ first, second ].map { _1.ticket.customer.identities.sole.external_id }
      expect(accounts.uniq.size).to eq(2)
      expect(EvalRun.count).to eq(2)
    end

    it "se o scheduler e o worker abrirem o turno antes do eval, o eval usa o mesmo turno e passa" do
      eager = lambda do |seconds|
        sleeper.call(seconds)
        Deadlines::DispatchDue.call(now: Time.current, limit: 100).each { Turns::Open.call(_1) }
      end

      run = Evals::Runner.call("corrida-3s", brand: infinitepay, clock:, sleeper: eager)

      expect(run.status).to eq("passed")
      expect(AiTurn.where(ticket_id: run.ticket_id).count).to eq(2)
    end
  end

  describe "marca" do
    it "JIM funciona igual e não toca dados da InfinitePay" do
      run = run_eval(brand: jim)

      expect(run).to have_attributes(status: "passed", brand_id: jim.id)
      expect(run.ticket.brand_id).to eq(jim.id)
      [ Ticket, Message, Customer, CustomerIdentity, AiTurn, AuditEvent, OutboxEvent ].each do |model|
        expect(model.where(brand_id: infinitepay.id).count).to eq(0), model.name
      end
    end
  end

  describe "comando bin/rails evals:run[corrida-3s]" do
    before do
      Rails.application.load_tasks if Rake::Task.tasks.none? { _1.name == "evals:run" }
      Rake::Task["evals:run"].reenable
      allow(Evals::Runner).to receive(:call).and_wrap_original do |original, name, **kwargs|
        original.call(name, **kwargs, clock:, sleeper:)
      end
    end

    after { ENV.delete("BRAND") }

    def invoke = JSON.parse(capture_stdout { Rake::Task["evals:run"].invoke("corrida-3s") })

    def capture_stdout
      previous = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = previous
    end

    it "roda na InfinitePay por padrão e imprime status, checagens e links em JSON" do
      output = invoke
      run = EvalRun.sole

      expect(output).to include("status" => "passed", "scenario" => "corrida-3s", "brand" => "infinitepay",
                                "eval_url" => "/evals/#{run.id}", "turn_url" => "/conversas/#{run.ticket_id}#turn-1")
      expect(output["checks"].map { _1["name"] }).to eq(check_names)
    end

    it "com RAILS_LOG_TO_STDOUT (logger no stdout, debug), a saída padrão é só o JSON, sem SQL nem texto de mensagem" do
      loggers = [ Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger ]
      previous = [ $stdout, $stderr ]
      $stdout = StringIO.new
      $stderr = StringIO.new
      stdout_logger = ActiveSupport::TaggedLogging.logger($stdout).tap { _1.level = :debug }
      Rails.logger = ActiveRecord::Base.logger = ActiveJob::Base.logger = stdout_logger
      ENV["RAILS_LOG_TO_STDOUT"] = "1"
      begin
        Rake::Task["evals:run"].invoke("corrida-3s")
        out = $stdout.string
        err = $stderr.string
        after = [ Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger ]
      ensure
        $stdout, $stderr = previous
        ENV.delete("RAILS_LOG_TO_STDOUT")
        Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger = loggers
      end

      expect { JSON.parse(out) }.not_to raise_error, out.lines.first(5).join
      expect(JSON.parse(out)).to include("status" => "passed")
      texts = Evals::Scenarios::CorridaTresSegundos::FIXTURE.values_at("messages", "actions").flatten.map { _1["text"] }
      expect(out).not_to include(*texts)
      expect(err).to include("INSERT INTO \"eval_runs\"", "eval.finished") # o log foi para o stderr, não sumiu
      expect(after).to all(be(stdout_logger)) # o task devolve os loggers no fim
    end

    it "BRAND=jim roda na JIM" do
      ENV["BRAND"] = "jim"

      expect(invoke).to include("brand" => "jim")
      expect(EvalRun.sole.brand_id).to eq(jim.id)
    end
  end
end
