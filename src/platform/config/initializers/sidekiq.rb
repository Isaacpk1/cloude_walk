# Sidekiq + Redis (ADR-005). A conexão vem de REDIS_URL. O Redis não é fonte da verdade: o que importa
# está no outbox do Postgres e a recuperação reoferece o que o Redis perder (ADR-016).
redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

Sidekiq.configure_client { |config| config.redis = redis }

Sidekiq.configure_server do |config|
  config.redis = redis
  # Logs em JSON (invariante 13).
  config.logger.formatter = Sidekiq::Logger::Formatters::JSON.new
  # O despertador das retentativas (1 s no RN-43) não pode esperar a varredura padrão de ~5 s.
  config.average_scheduled_poll_interval = 1
  # Recuperação do outbox enquanto o scheduler do bloco 08 não existe (07, seção 6).
  config.on(:startup) { Outbox::Sweeper.start }
  config.on(:shutdown) { Outbox::Sweeper.stop }
  # Sinal de vida para o healthcheck do Compose (RNF-29): renovado na subida e a cada batimento do
  # Sidekiq com o Redis (~10 s). Sem Redis, o arquivo envelhece e o worker aparece como unhealthy.
  if (heartbeat = ENV["SIDEKIQ_HEARTBEAT_FILE"].presence)
    config.on(:startup) { FileUtils.touch(heartbeat) }
    config.on(:beat) { FileUtils.touch(heartbeat) }
  end
end
