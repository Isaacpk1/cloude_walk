require "json"
require "helpdesk_contracts"

module FixtureHelpers
  FIXTURES = File.expand_path("../v1/fixtures", __dir__)

  def fixture(kind, contract, name)
    JSON.parse(File.read(File.join(FIXTURES, kind, contract.to_s, "#{name}.json"), encoding: "UTF-8"))
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
