require "json"
require "securerandom"
require "time"
require_relative "clock"
require_relative "chat_sender"
require_relative "platform_client"
require_relative "providers/chat"

module ChannelsMock
  # Cenários de rajada do simulador (ROADMAP, bloco 06; RN-55, RN-56; 07, seção 3.4, diagrama da corrida).
  # Cada cenário é uma lista de passos { at: segundos desde a largada, text: } enviados pelo mesmo
  # caminho do formulário (ChatSender: webhook do chat assinado, no contrato, guardado no Inbox), com
  # a mesma conta do provedor, o mesmo account_id e o mesmo customer_ref.
  #
  # mode :thread  (padrão) cada execução roda numa thread própria; a espera dorme até o horário planejado.
  # mode :manual  (testes) as execuções ficam paradas até drain!, que intercala os passos de todas pelo
  #               horário planejado. Com uma espera que só avança o Clock, nada dorme de verdade.
  module Scenarios
    Step = Data.define(:at, :text)
    Scenario = Data.define(:name, :title, :rule, :demonstrates, :steps)

    class UnknownScenario < StandardError; end

    # Tempos em segundos desde a largada. Mudar aqui muda a tela, o endpoint e o README.
    CATALOG = [
      Scenario.new(
        name: "corrida-3s", title: "Corrida dos 3 s", rule: "RN-56",
        demonstrates: "A mensagem 2 chega aos 3 s, depois de o turno 1 sair (janela de 1,5 s). A resposta do turno 1 " \
                      "é rejeitada por não cobrir a mensagem 2, e o turno 2 sai no teto de 4 s com as duas mensagens.",
        steps: [ Step.new(at: 0.0, text: "meu repasse não caiu"), Step.new(at: 3.0, text: "é o de ontem, R$ 1.200") ]
      ),
      Scenario.new(
        name: "rajada-curta", title: "Rajada curta", rule: "RN-55",
        demonstrates: "Três mensagens em 1 s, com pausas menores que a janela de 1,5 s: entram num turno só, " \
                      "que sai 1,5 s depois da última.",
        steps: [ Step.new(at: 0.0, text: "oi"), Step.new(at: 0.5, text: "meu repasse não caiu"),
                 Step.new(at: 1.0, text: "é o de ontem") ]
      ),
      Scenario.new(
        name: "rajada-longa", title: "Rajada longa (teto de 4 s)", rule: "RN-55",
        demonstrates: "Uma mensagem por segundo de 0 a 5 s: a janela nunca fecha, então o turno sai no teto de 4 s " \
                      "desde a primeira, antes do fim da rajada. A mensagem dos 5 s fica para o turno seguinte.",
        steps: [ "oi", "meu repasse não caiu", "era para ontem", "no valor de R$ 1.200", "na conta de sempre",
                 "alguém pode ver?" ].each_with_index.map { |text, i| Step.new(at: i.to_f, text:) }
      )
    ].to_h { [ _1.name, _1 ] }.freeze

    LIMIT = 20

    # Uma execução de um cenário. Guarda o horário planejado e o real de cada passo e a resposta da plataforma.
    class Run
      attr_reader :id, :scenario, :account, :started_at
      attr_writer :thread

      def initialize(id:, scenario:, account:, account_id:, customer_ref:, started_at:)
        @id = id
        @scenario = scenario
        @account = account
        @account_id = account_id
        @customer_ref = customer_ref
        @started_at = started_at
        @results = []
        @status = "queued"
        @lock = Mutex.new
      end

      def fields(step, message_id)
        { "account_id" => @account_id, "customer_ref" => @customer_ref, "text" => step.text, "message_id" => message_id }
      end

      def next_index = @lock.synchronize { @results.size }
      def done? = next_index >= scenario.steps.size
      def planned_at(index) = started_at + scenario.steps.fetch(index).at
      def next_planned_at = planned_at(next_index)
      def join(timeout = nil) = @thread&.join(timeout)

      def record(result)
        @lock.synchronize do
          @results << result
          @status = @results.size >= scenario.steps.size ? "finished" : "running"
        end
      end

      def snapshot
        @lock.synchronize do
          { "id" => id, "scenario" => scenario.name, "title" => scenario.title, "rule" => scenario.rule,
            "account" => account, "account_id" => @account_id, "customer_ref" => @customer_ref,
            "status" => @status, "started_at" => iso(started_at), "current_step" => @results.size,
            "total_steps" => scenario.steps.size,
            "steps" => scenario.steps.each_with_index.map { |step, i| step_view(step, i) } }
        end
      end

      private

      def step_view(step, index)
        { "step" => index + 1, "at" => step.at, "text" => step.text, "planned_at" => iso(planned_at(index)),
          "sent_at" => nil, "http_status" => nil, "outcome" => nil, "error" => nil, "message_id" => nil,
          "trace_id" => nil, "inbox_id" => nil }.merge(@results[index] || {})
      end

      def iso(time) = time.utc.iso8601(3)
    end

    @lock = Mutex.new

    class << self
      def reset!(mode: :thread, waiter: nil, sender: nil, client: nil, out: $stdout)
        @lock.synchronize do
          @mode = mode
          @waiter = waiter || ->(at) { wait_until(at) }
          client ||= PlatformClient.new(base_url: ENV.fetch("PLATFORM_URL", "http://localhost:3000"))
          @sender = sender || ->(account:, fields:) { ChatSender.call(client:, account:, fields:) }
          @out = out
          @runs = {}
          @next_id = 0
        end
      end

      def catalog = CATALOG.values

      # Valida tudo antes de criar a execução: nada sai para a plataforma se a largada for inválida.
      def start(name, account:, account_id:, customer_ref:)
        scenario = CATALOG[name.to_s] || raise(UnknownScenario, "cenário desconhecido: #{name}")
        raise ArgumentError, "conta desconhecida: #{account}" unless Providers::Chat::ACCOUNTS.include?(account)

        Providers::Chat.webhook(account_id:, customer_ref:, text: scenario.steps.first.text)
        run = register(scenario:, account:, account_id:, customer_ref:)
        log("scenario.started", run, "steps" => scenario.steps.size)
        run.thread = Thread.new { perform_all(run) } if @mode == :thread
        run
      end

      def find(id) = @lock.synchronize { @runs[id] }
      def runs = @lock.synchronize { @runs.values.reverse }

      # Modo manual: executa os passos pendentes de todas as execuções, do horário planejado mais cedo ao mais tarde.
      def drain!
        loop do
          pending = @lock.synchronize { @runs.values }.reject(&:done?)
          break if pending.empty?

          perform_step(pending.min_by { [ _1.next_planned_at, _1.id ] })
        end
      end

      # Espera real: dorme até o Clock alcançar o horário. Repete se acordar antes; nunca envia adiantado.
      def wait_until(at, sleeper: ->(seconds) { sleep(seconds) })
        loop do
          remaining = at - Clock.now
          break unless remaining.positive?

          sleeper.call(remaining)
        end
      end

      private

      def register(**attrs)
        @lock.synchronize do
          @next_id += 1
          run = Run.new(id: @next_id, started_at: Clock.now, **attrs)
          @runs[run.id] = run
          @runs.delete(@runs.keys.first) while @runs.size > LIMIT
          run
        end
      end

      def perform_all(run)
        perform_step(run) until run.done?
      rescue StandardError => e
        log("scenario.failed", run, "error" => e.class.name)
      end

      def perform_step(run)
        index = run.next_index
        step = run.scenario.steps.fetch(index)
        @waiter.call(run.planned_at(index))
        message_id = "chat_msg_#{SecureRandom.hex(6)}"
        sent_at = Clock.now
        result = send_step(run, step, message_id).merge("sent_at" => sent_at.utc.iso8601(3), "message_id" => message_id)
        run.record(result)
        log("scenario.step_sent", run, "step" => index + 1, "planned_at" => run.planned_at(index).utc.iso8601(3),
                                       **result.except("error"), "failed" => !result["error"].nil?)
        log("scenario.finished", run, "steps" => run.scenario.steps.size) if run.done?
      end

      def send_step(run, step, message_id)
        entry = @sender.call(account: run.account, fields: run.fields(step, message_id))
        { "http_status" => entry.response&.status, "outcome" => entry.outcome,
          "error" => entry.error || entry.response&.error, "trace_id" => entry.response&.trace_id, "inbox_id" => entry.id }
      rescue StandardError => e
        { "http_status" => nil, "outcome" => "Erro no envio", "error" => e.message, "trace_id" => nil, "inbox_id" => nil }
      end

      # RN-51: sem o texto nem os identificadores do cliente; só a execução, a conta do provedor e o resultado.
      def log(event, run, fields = {})
        line = JSON.generate({ "event" => event, "run_id" => run.id, "scenario" => run.scenario.name,
                               "account" => run.account, **fields })
        @lock.synchronize { @out.puts(line) }
      end
    end

    reset!
  end
end
