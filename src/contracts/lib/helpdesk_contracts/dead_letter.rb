require "json"

module HelpdeskContracts
  # Vista da mensagem de helpdesk.agent.dlq.v1 que o contrato :dead_letter valida (v1/schemas/dead_letter.json).
  #
  #   view = HelpdeskContracts::DeadLetter.view(headers: message.headers, payload: message.raw_payload, key:)
  #   HelpdeskContracts.errors(:dead_letter, view)
  #
  # A mensagem do Kafka não tem envelope: o corpo original vai como chegou e o motivo vai nos cabeçalhos
  # (07, seção 5.2). A vista junta os dois, com `dlq_violations` decodificado do JSON do cabeçalho. Cabeçalho
  # ilegível fica como texto, para o contrato apontar o defeito. O corpo é lido como UTF-8, com bytes
  # inválidos trocados por U+FFFD (a vista precisa virar JSON); quem guarda o corpo cru decide o que fazer.
  module DeadLetter
    REPLACEMENT = "�".freeze

    module_function

    def view(headers:, payload:, key: nil)
      flat = headers.to_h.to_h { |name, value| [ name.to_s, value.is_a?(Array) ? value.first : value ] }
      flat["dlq_violations"] = decode(flat["dlq_violations"]) if flat.key?("dlq_violations")
      { "key" => key, "headers" => flat, "payload" => text(payload) }
    end

    def text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
    end

    def decode(value)
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end
  end
end
