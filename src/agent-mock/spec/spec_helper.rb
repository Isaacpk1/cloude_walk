ENV["KARAFKA_ENV"] = "test"
require "json"
require "securerandom"
require "stringio"
require_relative "../lib/agent_mock"
require_relative "support/kafka"

RSpec.configure do |config|
  config.include KafkaHelpers
  config.disable_monkey_patching!
  config.order = :random
end
