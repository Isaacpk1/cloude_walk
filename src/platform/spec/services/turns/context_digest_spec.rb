require "rails_helper"

RSpec.describe Turns::ContextDigest, "RN-49, RN-55: digest do contexto do turno (07, seção 3.4)" do
  let(:context) do
    { "pending_messages" => [ { "seq" => 2, "text" => "é o de ontem, R$ 1.200" } ],
      "history" => [ { "seq" => 1, "author" => "customer", "text" => "oi" } ] }
  end

  it "é sha256: com o SHA-256 hex do JSON canônico (chaves ordenadas, sem espaços, UTF-8)" do
    canonical = '{"history":[{"author":"customer","seq":1,"text":"oi"}],' \
                '"pending_messages":[{"seq":2,"text":"é o de ontem, R$ 1.200"}]}'

    expect(described_class.canonical_json(context)).to eq(canonical)
    expect(described_class.call(context)).to eq("sha256:#{Digest::SHA256.hexdigest(canonical.encode('UTF-8'))}")
  end

  it "não depende da ordem das chaves nem de símbolo ou string, mas depende da ordem dos arrays" do
    reordered = { history: [ { text: "oi", seq: 1, author: "customer" } ],
                  pending_messages: [ { text: "é o de ontem, R$ 1.200", seq: 2 } ] }

    expect(described_class.call(reordered)).to eq(described_class.call(context))
    swapped = context.merge("history" => context["history"] + [ { "seq" => 0, "text" => "x" } ])
    expect(described_class.call(swapped)).not_to eq(described_class.call(swapped.merge("history" => swapped["history"].reverse)))
  end

  it "o digest segue o formato que o banco aceita" do
    expect(described_class.call(context)).to match(/\Asha256:[0-9a-f]{64}\z/)
  end
end
