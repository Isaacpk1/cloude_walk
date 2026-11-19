require "json"
require "pathname"
require "json_schemer"
require_relative "helpdesk_contracts/version"

# Validador único dos contratos do help desk (07, seção 5; RNF-28; invariante 10).
#
#   HelpdeskContracts.validate!(:agent_outbound, payload) # => payload ou InvalidPayload
#   HelpdeskContracts.valid?(:agent_outbound, payload)    # => true/false
#   HelpdeskContracts.errors(:agent_outbound, payload)    # => [Violation, ...]
#
# A versão sai do campo `schema` do payload (07, seção 5.4). Contratos sem esse
# campo (webhooks dos canais) usam o argumento `version:` ou a versão padrão.
module HelpdeskContracts
  ROOT = Pathname(__dir__).parent
  DEFAULT_VERSION = "v1".freeze
  SCHEMA_FIELD = /\Ahelpdesk\.(?<name>[a-z][a-z0-9_]*)\.(?<version>v\d+)\z/

  # Nome do contrato => arquivo em v*/schemas e nome usado no campo `schema`.
  # `decoded`: campos em base64 com JSON dentro, validados contra um $defs do próprio
  # esquema depois de decodificados (contentSchema é só anotação no draft 2020-12).
  CONTRACTS = {
    normalized_message: { file: "normalized_message.json", schema_name: "normalized_message" },
    agent_inbound: { file: "agent_inbound.json", schema_name: "agent_event" },
    agent_outbound: { file: "agent_outbound.json", schema_name: "agent_action" },
    # Entrada dos canais (07, seção 5.0; ADR-018).
    chat_webhook: { file: "channels/chat.json", schema_name: nil },
    chat_status: { file: "channels/chat_status.json", schema_name: nil },
    whatsapp_webhook: { file: "channels/whatsapp.json", schema_name: nil },
    whatsapp_send_response: { file: "channels/whatsapp_send_response.json", schema_name: nil },
    email_push: { file: "channels/email_push.json", schema_name: nil,
                  decoded: { "/message/data" => "#/$defs/notificacao" } },
    email_history: { file: "channels/email_history.json", schema_name: nil },
    email_message: { file: "channels/email_message.json", schema_name: nil },
    # Saída para os provedores (07, seção 5.0; ADR-018).
    chat_send: { file: "channels/outbound/chat.json", schema_name: nil },
    whatsapp_send: { file: "channels/outbound/whatsapp.json", schema_name: nil },
    email_send: { file: "channels/outbound/email.json", schema_name: nil }
  }.freeze

  # Uma violação do contrato. `pointer` é o JSON Pointer do dado ("" é a raiz).
  Violation = Data.define(:pointer, :type, :message) do
    def to_s = "#{pointer.empty? ? '/' : pointer}: #{message}"
  end

  class Error < StandardError; end

  # Payload fora do contrato: falha permanente, vai para a DLQ sem retentativa (RN-44).
  class InvalidPayload < Error
    attr_reader :contract, :violations

    def initialize(contract, violations)
      @contract = contract
      @violations = violations
      super("payload fora do contrato #{contract}: #{violations.map(&:to_s).join('; ')}")
    end
  end

  @schemers = {}
  @lock = Mutex.new

  class << self
    def contracts = CONTRACTS.keys

    def versions
      ROOT.glob("v*/schemas").map { |dir| dir.parent.basename.to_s }.sort_by { |v| v.delete_prefix("v").to_i }
    end

    def validate!(contract, payload, version: nil)
      violations = errors(contract, payload, version: version)
      raise InvalidPayload.new(contract_key(contract), violations) if violations.any?

      payload
    end

    def valid?(contract, payload, version: nil) = errors(contract, payload, version: version).empty?

    def errors(contract, payload, version: nil)
      key = contract_key(contract)
      data, violation = parse(payload)
      return [ violation ] if violation

      resolved, violation = resolve_version(key, data, version)
      return [ violation ] if violation

      violations = schemer(key, resolved).validate(data).flat_map { |error| to_violations(error) }
      violations + decoded_violations(key, resolved, data, violations)
    end

    # Contrato indicado pelo campo `schema`, ou nil se o nome não for conhecido.
    def contract_for(payload)
      data, = parse(payload)
      match = data.is_a?(Hash) && data["schema"].is_a?(String) && SCHEMA_FIELD.match(data["schema"])
      return unless match

      CONTRACTS.find { |_, spec| spec[:schema_name] == match[:name] }&.first
    end

    private

    def contract_key(contract)
      key = contract.to_s.to_sym
      return key if CONTRACTS.key?(key)

      raise ArgumentError, "contrato desconhecido: #{contract.inspect}. Conhecidos: #{contracts.join(', ')}"
    end

    # Aceita Hash (chaves String ou Symbol) ou o corpo bruto em JSON. Nunca muta o payload.
    # O corpo bruto é lido como UTF-8, qualquer que seja a codificação marcada na String
    # (corpo HTTP costuma chegar como ASCII-8BIT ou US-ASCII). UTF-8 inválido vira json_invalido.
    def parse(payload)
      json = payload.is_a?(String) ? payload.dup.force_encoding(Encoding::UTF_8) : JSON.generate(payload)
      return [ nil, json_invalido("UTF-8 inválido no corpo") ] unless json.valid_encoding?

      [ JSON.parse(json), nil ]
    rescue JSON::ParserError, JSON::GeneratorError, EncodingError => e
      [ nil, json_invalido("JSON malformado: #{e.message}") ]
    end

    def json_invalido(message) = Violation.new(pointer: "", type: "json_invalido", message: message)

    def resolve_version(key, data, requested)
      declared = declared_version(key, data)
      return [ nil, declared ] if declared.is_a?(Violation)

      if requested && declared && requested != declared
        return [ nil, unknown_version(key, requested, "payload declara #{declared}, pedido #{requested}") ]
      end

      version = requested || declared || DEFAULT_VERSION
      return [ version, nil ] if schema_path(key, version).file?

      [ nil, unknown_version(key, version, "versão #{version} não existe para #{key}") ]
    end

    # Versão do campo `schema`. Formato fora do padrão fica para o próprio esquema rejeitar.
    def declared_version(key, data)
      name = CONTRACTS.fetch(key)[:schema_name]
      return unless name && data.is_a?(Hash) && data["schema"].is_a?(String)

      match = SCHEMA_FIELD.match(data["schema"])
      return unless match
      return match[:version] if match[:name] == name

      Violation.new(pointer: "/schema", type: "schema_de_outro_contrato",
                    message: "#{data['schema']} não é o contrato #{key} (helpdesk.#{name}.vN)")
    end

    def unknown_version(key, _version, message)
      pointer = CONTRACTS.fetch(key)[:schema_name] ? "/schema" : ""
      Violation.new(pointer: pointer, type: "schema_desconhecido", message: message)
    end

    def schema_path(key, version) = ROOT.join(version, "schemas", CONTRACTS.fetch(key)[:file])

    def schemer(key, version)
      @lock.synchronize do
        # Lido como UTF-8 de forma explícita: contêineres costumam rodar com locale C.
        # Regex ECMA, como manda o JSON Schema: no Ruby, ^ e $ casam por linha e
        # "infinitepay\njim" passaria em ^[a-z0-9][a-z0-9_-]*$.
        @schemers[[ key, version ]] ||= JSONSchemer.schema(
          JSON.parse(schema_path(key, version).read(encoding: "UTF-8")), format: true, regexp_resolver: "ecma"
        )
      end
    end

    # `required` vira uma violação por campo ausente, com o pointer do campo (RFC 6901),
    # para a DLQ e as fixtures dizerem qual campo falta, não só o objeto pai.
    def to_violations(error, prefix = "")
      pointer = prefix + error.fetch("data_pointer")
      missing = error.dig("details", "missing_keys")
      return [ Violation.new(pointer: pointer, type: error.fetch("type"), message: error.fetch("error")) ] unless missing

      missing.map do |field|
        Violation.new(pointer: "#{pointer}/#{field.gsub('~', '~0').gsub('/', '~1')}", type: "required",
                      message: "campo obrigatório ausente: #{field} em #{pointer.empty? ? '/' : pointer}")
      end
    end

    # Campos em base64 com JSON dentro (ex.: message.data do Pub/Sub). Só valida o conteúdo
    # se o próprio campo passou no esquema. O pointer continua dentro do campo decodificado.
    def decoded_violations(key, version, data, violations)
      CONTRACTS.fetch(key).fetch(:decoded, {}).flat_map do |pointer, ref|
        next [] if violations.any? { |v| v.pointer == pointer || pointer.start_with?("#{v.pointer}/") }

        value = dig_pointer(data, pointer)
        next [] unless value.is_a?(String)

        decoded = decode_json(value)
        next [ Violation.new(pointer: pointer, type: "conteudo_invalido", message: "base64 sem JSON válido dentro") ] if decoded.nil?

        schemer(key, version).ref(ref).validate(decoded).flat_map { |error| to_violations(error, pointer) }
      end
    end

    def dig_pointer(data, pointer)
      pointer.split("/").drop(1).reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
    end

    # Pub/Sub usa base64 padrão. Aceita também base64url. Devolve nil se não for JSON.
    def decode_json(value)
      raw = value.tr("-_", "+/")
      raw += "=" * (-raw.length % 4)
      JSON.parse(raw.unpack1("m0").force_encoding("UTF-8"))
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end
