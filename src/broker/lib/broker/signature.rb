require "helpdesk_contracts"

module Broker
  # Assinatura do webhook plataforma → broker (RNF-23; 07, seção 5.2). Usa o mesmo código da
  # plataforma (HelpdeskContracts::Signature): só escolhe o segredo. Fora de produção há um
  # segredo de desenvolvimento, o mesmo que a plataforma usa sem a variável.
  module Signature
    DEV_SECRET = "dev-secret-broker".freeze

    module_function

    def secret(env: ENV)
      return env.fetch("BROKER_WEBHOOK_SECRET") if env["RACK_ENV"] == "production"

      env.fetch("BROKER_WEBHOOK_SECRET", DEV_SECRET)
    end

    def verify!(body, header, secret: self.secret)
      HelpdeskContracts::Signature.verify!(body, header, secret:)
    end
  end
end
