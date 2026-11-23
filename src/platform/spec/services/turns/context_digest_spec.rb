require "rails_helper"

RSpec.describe Turns::ContextDigest, "RN-49, RF-33: digest verificável do contexto do turno (07, seção 3.4)" do
  let(:context) do
    { "pending_messages" => [ { "seq" => 2, "text" => "é o de ontem, R$ 1.200" } ],
      "history" => [ { "seq" => 1, "author" => "customer", "text" => "meu repasse não caiu" } ] }
  end

  it "tem o formato sha256:<64 hex> do SHA-256 do JSON canônico" do
    canonical = '{"history":[{"author":"customer","seq":1,"text":"meu repasse não caiu"}],' \
                '"pending_messages":[{"seq":2,"text":"é o de ontem, R$ 1.200"}]}'

    expect(described_class.canonical_json(context)).to eq(canonical)
    expect(described_class.call(context)).to eq("sha256:#{Digest::SHA256.hexdigest(canonical)}")
    expect(described_class.call(context)).to match(/\Asha256:[0-9a-f]{64}\z/)
  end

  it "é estável para o mesmo conteúdo, qualquer que seja a ordem das chaves, inclusive aninhadas e simbólicas" do
    shuffled = { history: [ { text: "meu repasse não caiu", author: "customer", seq: 1 } ],
                 pending_messages: [ { "text" => "é o de ontem, R$ 1.200", "seq" => 2 } ] }

    expect(described_class.call(shuffled)).to eq(described_class.call(context))
  end

  it "é estável depois de ida e volta pelo jsonb (o Postgres reordena as chaves)" do
    stored = JSON.parse(JSON.generate(context.to_a.reverse.to_h))

    expect(described_class.call(stored)).to eq(described_class.call(context))
  end

  it "muda com qualquer alteração: texto, seq, ordem de um array, chave a mais" do
    base = described_class.call(context)
    variants = [
      context.deep_merge("pending_messages" => [ { "seq" => 2, "text" => "é o de ontem, R$ 1.201" } ]),
      context.deep_merge("pending_messages" => [ { "seq" => 3, "text" => "é o de ontem, R$ 1.200" } ]),
      context.merge("history" => context["history"] + [ { "seq" => 0, "author" => "bot", "text" => "x" } ]),
      context.merge("history" => ([ { "seq" => 0, "author" => "bot", "text" => "x" } ] + context["history"])),
      context.merge("summary" => nil)
    ]

    digests = variants.map { described_class.call(_1) }
    expect(digests).not_to include(base)
    expect(digests[2]).not_to eq(digests[3])
  end
end

RSpec.describe Turns::ContextDigest, "RN-49, RN-55: JSON canônico que o painel espera (07, seção 3.4)" do
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
