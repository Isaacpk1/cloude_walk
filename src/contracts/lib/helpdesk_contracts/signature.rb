require "openssl"

module HelpdeskContracts
  # Assinatura dos webhooks (07, seção 5.2; RNF-23; ADR-019). Faz parte do contrato: quem envia
  # e quem recebe precisam calcular igual. Usada pelo webhook plataforma → broker e pela entrada
  # dos canais próprios da CloudWalk (chat do app).
  #
  #   X-Helpdesk-Signature: t=<unix>,v1=<hex(HMAC-SHA256(segredo, "t.corpo_bruto"))>
  #
  # O `t` entra no HMAC, então trocar o horário invalida a assinatura. Fora de ±5 min, é replay.
  module Signature
    HEADER = "X-Helpdesk-Signature".freeze
    TOLERANCE = 300
    FORMAT = /\At=(?<t>\d{1,12}),v1=(?<v1>\h{64})\z/

    class Invalid < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("assinatura do webhook inválida: #{reason}")
      end
    end

    module_function

    def header(body, secret:, at: Time.now)
      t = at.to_i
      "t=#{t},v1=#{digest(secret, t, body)}"
    end

    # Recusa com o motivo. Compara em tempo constante. O corpo é o bruto, antes de qualquer parse.
    def verify!(body, header, secret:, now: Time.now, tolerance: TOLERANCE)
      raise Invalid, :sem_segredo if secret.to_s.empty?
      raise Invalid, :ausente if header.to_s.empty?

      match = FORMAT.match(header.to_s.strip) || raise(Invalid, :malformada)
      t = match[:t].to_i
      raise Invalid, :fora_da_janela if (now.to_i - t).abs > tolerance
      raise Invalid, :nao_confere unless OpenSSL.fixed_length_secure_compare(digest(secret, t, body), match[:v1].downcase)

      true
    end

    def digest(secret, t, body) = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{t}.#{body}")
  end
end
