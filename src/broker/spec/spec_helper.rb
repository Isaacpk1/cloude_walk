ENV["RACK_ENV"] = "test"
ENV["BROKER_WEBHOOK_SECRET"] = "segredo-de-teste-do-broker"
require "rack/test"
require "json"
require "securerandom"
require_relative "../app"
require_relative "support/kafka"

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.include KafkaHelpers
  config.disable_monkey_patching!
  config.order = :random
end
