require "rails_helper"

# ADR-023, item 5: o atendimento do eval nasce marcado (tickets.evaluation) no commit da primeira mensagem, pela
# conta de provedor de eval da marca. A marcação não muda depois (trigger, invariante 8).
RSpec.describe "ADR-023: marcação do atendimento de eval na ingestão" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }

  def ingest_from(account_slug, brand: "infinitepay", identity: "eval_#{SecureRandom.hex(4)}")
    msg = normalized_message(brand:, identity:).merge("provider_account" => account_slug)
    Ingestion::Receive.call(msg, provider_payload: {})
  end

  describe "ProviderAccount.evaluation_for!" do
    it "cria a conta <marca>-<canal>-eval inativa e marcada, e devolve a mesma na segunda chamada" do
      first = ProviderAccount.evaluation_for!(jim, "chat")
      second = ProviderAccount.evaluation_for!(jim, "chat")

      expect(first).to have_attributes(slug: "jim-chat-eval", brand_id: jim.id, channel: "chat", evaluation: true,
                                       active: false)
      expect(second.id).to eq(first.id)
      expect { ProviderAccount.find!(channel: "chat", slug: "jim-chat-eval") }.to raise_error(ProviderAccount::NotFound)
    end

    it "recusa um slug de eval que já existe como conta comum" do
      create(:provider_account, brand: jim, slug: "jim-chat-eval")

      expect { ProviderAccount.evaluation_for!(jim, "chat") }.to raise_error(ArgumentError, /não é a conta de eval/)
    end
  end

  it "mensagem pela conta de eval abre o atendimento marcado; pela conta comum, não" do
    ProviderAccount.evaluation_for!(infinitepay, "chat")

    expect(ingest_from("infinitepay-chat-eval").ticket.reload.evaluation).to be(true)
    expect(ingest_from("infinitepay-chat-mock").ticket.reload.evaluation).to be(false)
  end

  it "marca errada: a conta de eval da JIM não marca atendimento da InfinitePay" do
    ProviderAccount.evaluation_for!(jim, "chat")

    expect(ingest_from("jim-chat-eval", brand: "infinitepay").ticket.reload.evaluation).to be(false)
  end

  it "o banco recusa mudar a marcação depois da criação, nos dois sentidos" do
    ProviderAccount.evaluation_for!(infinitepay, "chat")
    marked = ingest_from("infinitepay-chat-eval").ticket
    normal = ingest_from("infinitepay-chat-mock").ticket

    [ [ marked, false ], [ normal, true ] ].each do |ticket, value|
      expect { Ticket.transaction(requires_new: true) { Ticket.where(id: ticket.id).update_all(evaluation: value) } }
        .to raise_error(ActiveRecord::StatementInvalid, /tickets.evaluation não muda/)
    end
    expect { Ticket.where(id: normal.id).update_all(evaluation: false) }.not_to raise_error
  end
end
