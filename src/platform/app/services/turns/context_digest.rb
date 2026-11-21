# Digest do contexto enviado num turno (RN-49, RN-55; 07, seção 3.4, "Contexto completo, de forma
# verificável"). Prova que o contexto gravado em ai_turns é o que a IA recebeu.
#
#   Turns::ContextDigest.call(context) # => "sha256:<64 hex>"
#
# JSON canônico: chaves ordenadas recursivamente, arrays na ordem, sem espaços, UTF-8. O Turns::Open
# grava o digest; o painel recalcula e compara.
module Turns
  module ContextDigest
    module_function

    def call(context) = "sha256:#{Digest::SHA256.hexdigest(canonical_json(context))}"

    def canonical_json(value) = JSON.generate(canonical(value)).encode(Encoding::UTF_8)

    def canonical(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
      when Array then value.map { canonical(_1) }
      else value
      end
    end
  end
end
