require "digest"
require "json"
require "yaml"

module AgentMock
  # Configuração efetiva do agente: config/scenarios.yml + perfil (AGENT_PROFILE) + sobreposições
  # por ENV (RF-38). O config_hash é o SHA-256 do JSON canônico dessa configuração efetiva,
  # e vai em toda ação (RN-37): duas execuções com o mesmo hash decidem igual (RNF-30).
  class Config
    DEFAULT_PATH = File.expand_path("../../config/scenarios.yml", __dir__)
    Latency = Data.define(:min, :max)
    Invalid = Class.new(ArgumentError)

    attr_reader :profile, :seed, :latency, :failure_rate, :mute, :max_ai_turns, :tools, :rules, :replies

    def self.load(path: DEFAULT_PATH, env: ENV) = new(YAML.safe_load_file(path), env:)

    def initialize(raw, env: ENV)
      @raw = raw
      @profile = env.fetch("AGENT_PROFILE", raw.fetch("default_profile"))
      settings = raw.fetch("profiles").fetch(@profile) { raise Invalid, "perfil desconhecido: #{@profile}" }
      @seed = integer(env.fetch("AGENT_SEED", raw.fetch("seed")), "AGENT_SEED")
      @latency = parse_latency(env.fetch("AGENT_LATENCY_MS", settings.fetch("latency_ms")))
      @failure_rate = parse_failure_rate(env.fetch("AGENT_FAILURE_RATE", settings.fetch("failure_rate")))
      @mute = parse_boolean(env.fetch("AGENT_MUTE", settings.fetch("mute")))
      @max_ai_turns = integer(raw.fetch("max_ai_turns"), "max_ai_turns")
      @tools = raw.fetch("tools")
      @rules = raw.fetch("rules")
      # Regra inválida derruba a subida aqui, não no primeiro evento.
      @rules.each { Scenarios::Rule.new(_1) }
      @replies = raw.fetch("replies")
    end

    def effective
      {
        "version" => @raw.fetch("version"), "profile" => profile, "seed" => seed,
        "latency_ms" => { "min" => latency.min, "max" => latency.max },
        "failure_rate" => failure_rate, "mute" => mute, "max_ai_turns" => max_ai_turns,
        "tools" => tools, "rules" => rules, "replies" => replies
      }
    end

    def config_hash = @config_hash ||= "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(effective)))}"

    private

    def canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |k| [ k, canonical(value[k] || value[k.to_sym]) ] }
      when Array then value.map { canonical(_1) }
      else value
      end
    end

    # 200, "200", "1000-3000" ou { min:, max: }.
    def parse_latency(value)
      min, max = case value
      when Hash then [ value.fetch("min"), value.fetch("max") ]
      when /\A\s*(\d+)\s*-\s*(\d+)\s*\z/ then [ $1, $2 ]
      else [ value, value ]
      end
      min = integer(min, "latency_ms")
      max = integer(max, "latency_ms")
      raise Invalid, "latency_ms inválida: #{value.inspect}" if min.negative? || max < min

      Latency.new(min:, max:)
    end

    def parse_failure_rate(value)
      rate = Float(value)
      raise Invalid, "AGENT_FAILURE_RATE fora de 0..1: #{value.inspect}" unless rate.between?(0.0, 1.0)

      rate
    rescue ArgumentError, TypeError
      raise Invalid, "AGENT_FAILURE_RATE inválida: #{value.inspect}"
    end

    def parse_boolean(value)
      case value.to_s.strip.downcase
      when "true", "1", "yes", "sim" then true
      when "false", "0", "no", "nao", "" then false
      else raise Invalid, "AGENT_MUTE inválido: #{value.inspect}"
      end
    end

    def integer(value, name)
      Integer(value)
    rescue ArgumentError, TypeError
      raise Invalid, "#{name} inválido: #{value.inspect}"
    end
  end
end
