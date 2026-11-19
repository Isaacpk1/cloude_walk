require "rails_helper"

RSpec.describe ConversationReader, "ROADMAP 01: formato de leitura estável" do
  after { described_class.source = nil }

  it "usa os exemplos sintéticos enquanto não existe adaptador dos registros reais" do
    expect(described_class.source).to be_a(SyntheticConversations)
  end

  it "delega a qualquer fonte com a mesma interface" do
    fake = instance_double(SyntheticConversations, all: [], find: :conversa, timeline: :linha)
    described_class.source = fake

    expect(described_class.all).to eq([])
    expect(described_class.find("x")).to eq(:conversa)
    expect(described_class.timeline("x")).to eq(:linha)
  end

  it "levanta NotFound quando a fonte não encontra a conversa" do
    described_class.source = instance_double(SyntheticConversations, find: nil, timeline: nil)

    expect { described_class.find("x") }.to raise_error(ConversationReader::NotFound)
    expect { described_class.timeline("x") }.to raise_error(ConversationReader::NotFound)
  end
end
