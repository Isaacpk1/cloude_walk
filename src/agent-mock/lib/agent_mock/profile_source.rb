require "redis"

module AgentMock
  # De onde vem o perfil escolhido pelo simulador em tempo de execução (RF-38; ROADMAP, bloco 08).
  #
  # O simulador (channels-mock) grava o nome do perfil num Redis de controle, separado do Redis do
  # Sidekiq (outro banco lógico), e o agente lê a cada evento. Não há acoplamento síncrono com o
  # simulador nem leitura do Postgres da plataforma (invariante 12): o Redis é só um quadro de avisos.
  #
  #   helpdesk:agent-mock:profile:brand:<marca>  vale para os eventos daquela marca (campo brand do evento)
  #   helpdesk:agent-mock:profile:global         vale para todas as marcas sem perfil próprio
  #
  # A marca tem precedência sobre o global; sem nenhum dos dois, vale o AGENT_PROFILE.
  # O agente não vê o account_id nem o customer_ref do simulador (o evento só traz cus_<id> da
  # plataforma), por isso o escopo mais fino é a marca, que a conta do provedor define.
  class ProfileSource
    PREFIX = "helpdesk:agent-mock:profile".freeze
    Choice = Data.define(:profile, :scope)
    # Falhar rápido: um Redis fora do ar não pode segurar a thread do consumidor.
    TIMEOUT = 0.2

    def self.key(scope) = "#{PREFIX}:#{scope}"

    # Sem AGENT_CONTROL_REDIS_URL não há fonte: vale só o AGENT_PROFILE (como antes do bloco 08).
    def self.build(env: ENV)
      url = env["AGENT_CONTROL_REDIS_URL"].to_s
      return nil if url.empty?

      new(redis: Redis.new(url:, connect_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT,
                           reconnect_attempts: 0))
    end

    attr_reader :redis

    def initialize(redis:) = @redis = redis

    # Uma ida ao Redis por evento (MGET). Erros do Redis sobem para o Profiles, que cai no padrão.
    def lookup(brand)
      brand_profile, global_profile = @redis.mget(self.class.key("brand:#{brand}"), self.class.key("global"))
      return Choice.new(profile: brand_profile, scope: "brand") if present?(brand_profile)

      Choice.new(profile: global_profile, scope: "global") if present?(global_profile)
    end

    private

    def present?(value) = !value.to_s.strip.empty?
  end
end
