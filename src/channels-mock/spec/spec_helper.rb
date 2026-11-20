ENV["RACK_ENV"] = "test"
require "rack/test"
require "webmock/rspec"
require_relative "../app"

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.disable_monkey_patching!
  config.order = :random
  config.before { ChannelsMock::Inbox.clear }
end
