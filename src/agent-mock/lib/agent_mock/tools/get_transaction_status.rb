module AgentMock
  module Tools
    # Status da última transação do cliente.
    class GetTransactionStatus < Base
      STATUSES = %w[aprovada em_analise recusada].freeze

      def self.args_for(event, _text) = { "customer_id" => event.dig("customer", "id"), "reference" => "ultima" }

      private

      def result_for(args)
        { "reference" => format("TX-%06d", number(args, "reference", 0..999_999)),
          "status" => pick(args, "status", STATUSES), "amount" => cents(args, "amount", 1_000..300_000) }
      end
    end
  end
end
