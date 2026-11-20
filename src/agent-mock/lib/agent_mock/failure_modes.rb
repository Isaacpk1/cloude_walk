module AgentMock
  # Modos de falha do agente (RF-38, ADR-008; experimentos E2 e E4):
  #
  # - latência: fixa ou numa faixa, sorteada com a semente e o event_id (RNF-30);
  # - taxa de falha: a ação não sai, como um erro do agente. Não levanta exceção: o Karafka
  #   reprocessaria o mesmo evento, que falharia de novo com a mesma semente. A plataforma
  #   trata a falta de resposta pelo prazo do turno (RN-46);
  # - modo mudo: consome e não responde nada.
  class FailureModes
    def initialize(config) = @config = config

    def mute? = @config.mute

    def latency_ms(event_id)
      latency = @config.latency
      return latency.min if latency.min == latency.max

      Seeded.random(@config.seed, "latency", event_id).rand(latency.min..latency.max)
    end

    def fail?(event_id)
      rate = @config.failure_rate
      return false if rate.zero?
      return true if rate >= 1.0

      Seeded.random(@config.seed, "failure", event_id).rand < rate
    end
  end
end
