module AgentMock
  module Tools
    # Taxa por meio de pagamento, da tabela da marca. Não é dado de conta: vale para cliente
    # não verificado (RN-05, config/scenarios.yml, account_data: false).
    class GetFee < Base
      METHODS = { "pix" => "pix", "debito" => "debito" }.freeze

      def self.args_for(event, text)
        method = METHODS.find { |term, _| Text.include_term?(text, term) }&.last || "credito"
        { "brand" => event.fetch("brand"), "method" => method }
      end

      private

      def result_for(args)
        { "method" => args.fetch("method"), "rate" => number(args, "rate", 0..499) / 100.0,
          "settlement_days" => args.fetch("method") == "credito" ? 1 : 0 }
      end
    end
  end
end
