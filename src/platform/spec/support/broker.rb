require "webmock/rspec"

# O broker é outro serviço (docs/10, O5): nos testes da plataforma, a chamada HTTP é simulada.
# O stub confere a assinatura e o contrato como o broker real (src/broker), para o teste não aceitar
# o que o broker recusaria.
module BrokerHelpers
  BROKER_URL = "http://broker.test:4100/webhooks".freeze

  def broker_secret = Outbox::BrokerClient.secret

  def stub_broker(*responses)
    responses = [ { status: 200 } ] if responses.empty?
    @broker_requests = []
    stub_request(:post, BROKER_URL).to_return(*responses.map { |r| broker_response(r) }).with do |request|
      @broker_requests << request
      true
    end
  end

  def broker_requests = @broker_requests || []

  # Resposta como a do broker para cada caso (src/broker/README.md).
  def broker_response(response)
    return response if response.key?(:body)

    body = case response[:status]
    when 200 then { status: "published", topic: "helpdesk.agent.inbound.v1", partition: 7, offset: 42 }
    when 401 then { status: "unauthorized", reason: "nao_confere" }
    when 422 then { status: "invalid", reason: "contrato", violations: [ { pointer: "/turn", type: "required" } ] }
    when 503 then { status: "unavailable", error: "Kafka sem confirmação" }
    else {}
    end
    response.merge(body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  def verify_broker_request!(request)
    HelpdeskContracts::Signature.verify!(request.body, request.headers["X-Helpdesk-Signature"], secret: broker_secret)
    HelpdeskContracts.validate!(:agent_inbound, request.body)
  end
end

RSpec.configure do |config|
  config.include BrokerHelpers
  config.before do
    allow(Outbox::BrokerClient).to receive(:url).and_return(BrokerHelpers::BROKER_URL)
  end
end

# O navegador dos testes de sistema fala com o servidor local.
WebMock.disable_net_connect!(allow_localhost: true)
