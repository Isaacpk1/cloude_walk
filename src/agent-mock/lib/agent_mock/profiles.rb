module AgentMock
  # Perfil efetivo de cada evento (RF-38): o escolhido pelo simulador (ProfileSource) ou, sem escolha,
  # o padrão do ambiente (AGENT_PROFILE). Cada perfil tem a configuração, os modos de falha e o motor
  # já montados na subida: um perfil inválido no YAML derruba a subida, não o primeiro evento.
  #
  # O config_hash é o da configuração do perfil efetivo (RN-37): a auditoria da plataforma mostra com
  # qual perfil a IA respondeu, mesmo depois de o simulador trocar.
  #
  # Nunca levanta erro por causa da fonte: Redis fora do ar ou perfil desconhecido gravado viram log
  # e o perfil padrão. O consumo segue (07, seção 6).
  class Profiles
    Runtime = Data.define(:config, :failures, :engine, :source)

    def initialize(config:, source: nil, log: Log.new)
      @default = config
      @source = source
      @log = log
      @runtimes = config.profile_names.to_h { |name| [ name, build(config.with_profile(name)) ] }
    end

    def names = @runtimes.keys

    # source: "brand" ou "global" (escolha do simulador) ou "env" (AGENT_PROFILE).
    def resolve(brand, trace_id: nil)
      choice = @source&.lookup(brand)
      return fallback unless choice

      runtime = @runtimes[choice.profile]
      return runtime.with(source: choice.scope) if runtime

      @log.warn("agent.profile_unknown", trace_id:, brand:, profile: choice.profile.to_s[0, 40], scope: choice.scope,
                                         fallback: @default.profile)
      fallback
    rescue Redis::BaseError, SystemCallError, IOError => e
      @log.warn("agent.profile_source_failed", trace_id:, brand:, error: e.class.name, fallback: @default.profile)
      fallback
    end

    private

    def fallback = @runtimes.fetch(@default.profile)

    def build(config)
      Runtime.new(config:, failures: FailureModes.new(config), engine: Scenarios.build_engine(config), source: "env")
    end
  end
end
