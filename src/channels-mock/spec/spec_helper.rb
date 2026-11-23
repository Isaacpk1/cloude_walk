ENV["RACK_ENV"] = "test"
require "rack/test"
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
    ChannelsMock::StatusCallbacks.reset!(mode: :manual)
    # Relógio controlado: nada de sleep nem de Time.now nos testes.
    ChannelsMock::Clock.freeze(Time.utc(2026, 11, 20, 12, 0, 0))
  end
  config.after { ChannelsMock::Clock.unfreeze }
end
