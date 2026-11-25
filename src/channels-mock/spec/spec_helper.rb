ENV["RACK_ENV"] = "test"
# Os testes assumem o padrão do código. No Compose o contêiner já traz PLATFORM_URL (http://web:3000) e outras; sem
# limpar, os stubs do WebMock (localhost) não casam e 36 testes falham.
%w[PLATFORM_URL PLATFORM_PUBLIC_URL CHAT_PROVIDER_FAULT CHAT_PROVIDER_FAULT_TIMES AGENT_CONTROL_REDIS_URL].each { ENV.delete(_1) }
require "rack/test"
require "stringio"
require "webmock/rspec"
require_relative "../app"
Dir[File.join(__dir__, "support", "*.rb")].each { require _1 }

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.disable_monkey_patching!
  config.order = :random
  config.before do
    ChannelsMock::Inbox.clear
    ChannelsMock::ChatDeliveries.clear
    ChannelsMock::Faults.clear
    # Redis de controle do perfil do agente em memória: os testes não dependem de um Redis de verdade.
    ChannelsMock::AgentProfile.reset!(redis: FakeControlRedis.new, out: StringIO.new)
    ChannelsMock::StatusCallbacks.reset!(mode: :manual)
    # Relógio controlado: nada de sleep nem de Time.now nos testes.
    ChannelsMock::Clock.freeze(Time.utc(2026, 11, 20, 12, 0, 0))
    # Cenários de rajada parados até drain!; a espera só avança o relógio congelado.
    ChannelsMock::Scenarios.reset!(mode: :manual, out: StringIO.new,
                                   waiter: ->(at) { ChannelsMock::Clock.freeze(at) if at > ChannelsMock::Clock.now })
  end
  config.after { ChannelsMock::Clock.unfreeze }
end
