# Digest verificável do contexto de um turno (07, seção 3.4, "Contexto completo, de forma verificável";
# RN-49, RF-33).
#
#   Turns::ContextDigest.call(context) # => "sha256:<64 hex>"
#
# JSON canônico: chaves dos objetos ordenadas recursivamente (como texto), arrays na ordem, sem espaços,
# UTF-8 sem escapes. O mesmo conteúdo dá o mesmo digest em qualquer ordem de chaves, inclusive depois da
# ida e volta pelo jsonb; qualquer mudança de valor, ordem de array ou chave muda o digest. O turno grava
# o digest do `context` que vai no evento, e o painel usa esta mesma função para conferir.
module Turns
  module ContextDigest
    PREFIX = "sha256:".freeze

    module_function

    def call(context) = "#{PREFIX}#{Digest::SHA256.hexdigest(canonical_json(context))}"

    def canonical_json(value) = JSON.generate(canonical(value))

    def canonical(value)
      case value
      when Hash then value.to_h { |k, v| [ k.to_s, canonical(v) ] }.sort.to_h
      when Array then value.map { canonical(_1) }
      else value
      end
    end
  end
end
