# Garante que um teste que troca a fonte do ConversationReader não vaze para o próximo.
RSpec.configure do |config|
  config.after(:each, file_path: %r{spec/(requests|system|read_models)/}) { ConversationReader.source = nil }
end
