require_relative "tools/base"
require_relative "tools/get_settlement_status"
require_relative "tools/get_transaction_status"
require_relative "tools/get_fee"

module AgentMock
  # Catálogo fechado de consultas (RF-32, RN-35). Uma tool fora daqui não existe.
  module Tools
    CATALOG = [ GetSettlementStatus, GetTransactionStatus, GetFee ].to_h { [ _1.tool_name, _1 ] }.freeze

    def self.fetch(name) = CATALOG.fetch(name) { raise ArgumentError, "tool desconhecida: #{name}" }
  end
end
