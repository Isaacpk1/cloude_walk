require "json"
require "redis"
require_relative "clock"
require_relative "providers/chat"

module ChannelsMock
  # Perfil do agente mock escolhido na tela ou por script (RF-38; ROADMAP, bloco 08, Frontend).
  #
  # Grava o nome do perfil no Redis de controle (AGENT_CONTROL_REDIS_URL), que o agent-mock lê a cada
  # evento (src/agent-mock/lib/agent_mock/profile_source.rb). Nada passa pelo caminho do evento: o
  # simulador só deixa o recado, e o agente decide sozinho.
  #
  #   global                  → helpdesk:agent-mock:profile:global
  #   <conta do provedor>     → helpdesk:agent-mock:profile:brand:<marca da conta>
  #
  # O escopo mais fino é a conta do provedor (= a marca): o evento do agente traz o cus_<id> da
  # plataforma, não o account_id nem o customer_ref do simulador. "padrao" apaga a escolha e volta a
  # valer o AGENT_PROFILE do agente.
  module AgentProfile
    PREFIX = "helpdesk:agent-mock:profile".freeze
    Profile = Data.define(:name, :title, :latency, :demonstrates)
    PROFILES = [
      Profile.new(name: "rapido", title: "Rápido", latency: "50–150 ms",
                  demonstrates: "Caminho feliz: a resposta chega antes de qualquer aviso."),
      Profile.new(name: "lento", title: "Lento", latency: "16–18 s",
                  demonstrates: "O cliente recebe o aviso de progresso aos 15 s (RN-57) e a resposta chega antes " \
                                "do prazo do turno de 20 s (RN-46)."),
      Profile.new(name: "mudo", title: "Sem resposta", latency: "não responde",
                  demonstrates: "Aviso de progresso aos 15 s, timeout do turno aos 20 s e o caso vai para a fila " \
                                "humana (RN-46, RN-33).")
    ].freeze
    CLEAR = "padrao".freeze
    BRANDS = { "infinitepay-chat-mock" => "infinitepay", "jim-chat-mock" => "jim" }.freeze
    SCOPES = [ "global", *Providers::Chat::ACCOUNTS ].freeze
    TIMEOUT = 0.2

    UnknownProfile = Class.new(ArgumentError)
    UnknownScope = Class.new(ArgumentError)
    # Controle desligado (sem AGENT_CONTROL_REDIS_URL) ou Redis fora do ar.
    Disabled = Class.new(StandardError)
    Unavailable = Class.new(StandardError)

    @lock = Mutex.new

    class << self
      attr_reader :redis

      def reset!(redis:, out: $stdout)
        @lock.synchronize do
          @redis = redis
          @out = out
        end
      end

      def configure_from(env, out: $stdout)
        url = env["AGENT_CONTROL_REDIS_URL"].to_s
        redis = url.empty? ? nil : Redis.new(url:, connect_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT)
        reset!(redis:, out:)
      end

      def key(scope) = scope == "global" ? "#{PREFIX}:global" : "#{PREFIX}:brand:#{BRANDS.fetch(scope)}"
      def find(name) = PROFILES.find { _1.name == name }

      # Valida antes de tocar o Redis: perfil ou escopo inválido não grava nada.
      def set(scope:, profile:)
        scope = scope.to_s
        profile = profile.to_s
        raise UnknownScope, "escopo desconhecido: #{scope}" unless SCOPES.include?(scope)
        raise UnknownProfile, "perfil desconhecido: #{profile}" unless profile == CLEAR || find(profile)

        with_redis { profile == CLEAR ? _1.del(key(scope)) : _1.set(key(scope), profile) }
        log("agent_profile.set", scope:, brand: BRANDS[scope], profile:)
        state
      end

      # O que o agente vai usar em cada escopo: perfil da marca → global → AGENT_PROFILE (source "env").
      def state
        global, *brands = with_redis { _1.mget(*SCOPES.map { |scope| key(scope) }) }
        scopes = SCOPES.zip([ global, *brands ]).map { |scope, profile| scope_state(scope, profile, global) }
        { "available" => true, "profiles" => PROFILES.map(&:to_h).map { _1.transform_keys(&:to_s) }, "scopes" => scopes }
      end

      # Para a tela: nunca levanta; devolve o motivo quando o controle não está disponível.
      def view_state
        state
      rescue Disabled, Unavailable => e
        { "available" => false, "error" => e.message, "profiles" => PROFILES.map { _1.to_h.transform_keys(&:to_s) },
          "scopes" => [] }
      end

      private

      def scope_state(scope, profile, global)
        profile = present(profile)
        global = present(global)
        effective, source = if profile then [ profile, scope == "global" ? "global" : "brand" ]
        elsif global then [ global, "global" ]
        else [ nil, "env" ]
        end
        { "scope" => scope, "brand" => BRANDS[scope], "profile" => profile, "effective" => effective, "source" => source }
      end

      def present(value) = value.to_s.strip.empty? ? nil : value

      def with_redis
        redis = @lock.synchronize { @redis }
        raise Disabled, "controle desligado: defina AGENT_CONTROL_REDIS_URL" unless redis

        yield redis
      rescue Redis::BaseError, SystemCallError, IOError => e
        log("agent_profile.unavailable", error: e.class.name)
        raise Unavailable, "Redis de controle indisponível (#{e.class.name})"
      end

      def log(event, **fields)
        line = JSON.generate({ "event" => event, **fields.transform_keys(&:to_s) }.compact
                               .merge("at" => Clock.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")))
        @lock.synchronize { @out&.puts(line) }
      end
    end
  end
end
