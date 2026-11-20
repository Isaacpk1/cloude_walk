# Kafka sem cluster nos testes (ADR-004, docs/10): o produtor do Karafka grava em memória
# (`karafka.produced_messages`) e o consumer recebe mensagens por `karafka.produce`.
require "karafka/testing/rspec/helpers"

RSpec.configure { |c| c.include Karafka::Testing::RSpec::Helpers }
