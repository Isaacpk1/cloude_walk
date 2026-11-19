# System specs rodam com rack_test (sem navegador nem JavaScript) até existir tela com Stimulus.
RSpec.configure do |config|
  config.before(:each, type: :system) { driven_by :rack_test }
end
