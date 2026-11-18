# Testes marcados com :concurrency rodam fora da transação de teste,
# com conexões separadas, e limpam o banco por truncation (AGENTS.md, item 3).
require "database_cleaner/active_record"

RSpec.configure do |config|
  config.around(:each, :concurrency) do |example|
    self.use_transactional_tests = false
    example.run
  ensure
    DatabaseCleaner.clean_with(:truncation)
  end
end

module ConcurrencyHelpers
  # Dispara o bloco em `threads` threads ao mesmo tempo, cada uma com a própria conexão.
  def run_concurrently(threads: 2)
    gate = Queue.new
    workers = Array.new(threads) do |i|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection { yield i }
      rescue StandardError => e
        e
      end
    end
    threads.times { gate << true }
    workers.map(&:value)
  end
end

RSpec.configure { |c| c.include ConcurrencyHelpers, :concurrency }
