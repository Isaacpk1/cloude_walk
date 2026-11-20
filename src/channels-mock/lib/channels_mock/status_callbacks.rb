require "time"
require_relative "clock"
require_relative "chat_deliveries"
require_relative "platform_client"

module ChannelsMock
  # Callback de status do chat (07, seção 5.0; interface do bloco 05, seção 3): depois de aceitar uma
  # mensagem, o provedor avisa a plataforma em POST /webhooks/chat/:conta/status, fora do caminho da
  # resposta. Fila em memória com uma thread; retentativa simples quando a plataforma não responde ou
  # responde 5xx. Um 4xx é definitivo (assinatura ou contrato): não adianta repetir.
  #
  # mode :thread  (padrão) uma thread consome a fila.
  # mode :manual  (testes) os jobs ficam na fila até drain!, sem thread e sem sleep.
  module StatusCallbacks
    Job = Data.define(:account, :message_id, :status, :timestamp)
    MAX_ATTEMPTS = Integer(ENV.fetch("CHAT_STATUS_MAX_ATTEMPTS", "5"))
    BACKOFF = 0.5

    @lock = Mutex.new

    class << self
      def reset!(mode: :thread, client: nil, sleeper: nil)
        @lock.synchronize do
          @mode = mode
          @client = client || PlatformClient.new(base_url: ENV.fetch("PLATFORM_URL", "http://localhost:3000"))
          @sleeper = sleeper || (mode == :manual ? ->(_) { } : ->(seconds) { sleep(seconds) })
          @queue = Queue.new
          @worker = nil
        end
      end

      def enqueue(account:, message_id:, status:)
        job = Job.new(account:, message_id:, status:, timestamp: Clock.now.utc.iso8601(3))
        HelpdeskContracts.validate!(:chat_status, payload(job))
        @queue << job
        start_worker if @mode == :thread
        job
      end

      def pending = @queue.size

      # Processa a fila agora, na thread de quem chama. Só para o modo manual (testes e demonstração).
      def drain!
        perform(@queue.pop) until @queue.empty?
      end

      def perform(job)
        attempts = 0
        response = nil
        loop do
          attempts += 1
          response = @client.deliver_status(account: job.account, payload: payload(job))
          break unless retry?(response) && attempts < MAX_ATTEMPTS

          @sleeper.call(BACKOFF * (2**(attempts - 1)))
        end
        ChatDeliveries.record_status(job.message_id, "status" => job.status, "timestamp" => job.timestamp,
                                                     "attempts" => attempts, "http_status" => response.status,
                                                     "error" => response.error)
      end

      private

      def payload(job) = { "message_id" => job.message_id, "status" => job.status, "timestamp" => job.timestamp }

      def retry?(response) = response.status.nil? || response.status >= 500

      def start_worker
        @lock.synchronize do
          return if @worker&.alive?

          @worker = Thread.new do
            loop { perform(@queue.pop) }
          rescue StandardError => e
            warn({ "event" => "chat_status.worker_failed", "error" => e.message }.to_json)
          end
        end
      end
    end

    reset!
  end
end
