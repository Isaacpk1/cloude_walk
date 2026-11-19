require "yaml"
require_relative "../config/waterdrop"

RSpec.describe "Configuração do Kafka (ADR-004; 07, seção 7)" do
  let(:topics) { YAML.safe_load_file(File.expand_path("../../../infra/kafka/topics.yml", __dir__)).fetch("topics") }

  it "RF-30: o produtor espera a confirmação de todas as réplicas e é idempotente" do
    config = Broker::Kafka.config(env: { "KAFKA_BROKERS" => "kafka:9092" })

    expect(config).to include("bootstrap.servers": "kafka:9092", "request.required.acks": -1, "enable.idempotence": true)
    expect(config.fetch(:"message.timeout.ms")).to be <= 10_000
  end

  it "usa localhost:9092 fora do Compose" do
    expect(Broker::Kafka.config(env: {})).to include("bootstrap.servers": "localhost:9092")
  end

  it "ADR-004: os tópicos do broker existem em infra/kafka/topics.yml com 48 partições" do
    declared = topics.to_h { [ _1.fetch("name"), _1 ] }

    Broker::TOPICS.each_value do |name|
      expect(declared.fetch(name).fetch("partitions")).to eq(48)
    end
    expect(declared.keys).to contain_exactly("helpdesk.agent.inbound.v1", "helpdesk.agent.outbound.v1", "helpdesk.agent.dlq.v1")
  end

  it "RNF-16, RN-48: a DLQ fica retida por no mínimo 7 dias" do
    dlq = topics.find { _1["name"] == "helpdesk.agent.dlq.v1" }

    expect(dlq.dig("config", "retention.ms").to_i).to be >= 7 * 24 * 3600 * 1000
  end
end

RSpec.describe "kafka-init: infra/kafka/create-topics.sh (docs/10, seção 3.7)" do
  it "cria cada tópico do topics.yml só se ele não existir, com partições e retenção" do
    script = File.expand_path("../../../infra/kafka/create-topics.sh", __dir__)
    output = IO.popen({ "DRY_RUN" => "1", "KAFKA_BOOTSTRAP" => "kafka:9092" }, [ "sh", script ], &:read)

    lines = output.lines
    expect(lines.size).to eq(3)
    expect(lines).to all(include("--bootstrap-server kafka:9092 --create --if-not-exists", "--partitions 48",
                                 "--config retention.ms=604800000"))
    expect(lines.first).to include("--topic helpdesk.agent.inbound.v1")
  end
end
