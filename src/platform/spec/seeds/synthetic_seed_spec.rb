require "rails_helper"
require Rails.root.join("db/seeds/synthetic")

RSpec.describe "RF-61: seed sintético reprodutível" do
  def snapshot
    {
      brands: Brand.order(:slug).pluck(:slug, :name),
      teams: Team.joins(:brand).order("brands.slug", :name).pluck("brands.slug", :name),
      users: User.order(:email).pluck(:email, :kind, :role),
      customers: Customer.joins(:brand).order("brands.slug", :display_name).pluck("brands.slug", :display_name, :verified),
      identities: CustomerIdentity.order(:external_id).pluck(:channel, :external_id),
      queues: QueueVersion.order(:name).pluck(:name, :version, :ai_first)
    }
  end

  it "cria marca, fila, cliente sintético e usuário bot (bloco 01)" do
    Seeds::Synthetic.call(seed: 42)

    expect(Brand.pluck(:slug)).to include("infinitepay", "jim")
    expect(User.where(kind: "bot")).to exist
    expect(HelpdeskQueue.where(is_default: true).count).to eq(Brand.count)
    expect(Customer.count).to be >= 1
    expect(HelpdeskQueue.all).to all(have_attributes(current_version: be_present))
  end

  it "a mesma semente produz os mesmos dados" do
    Seeds::Synthetic.call(seed: 42)
    first = snapshot
    DatabaseCleaner.clean_with(:truncation)

    Seeds::Synthetic.call(seed: 42)

    expect(snapshot).to eq(first)
  end

  it "rodar duas vezes não duplica nada (repetição)" do
    Seeds::Synthetic.call(seed: 42)
    counts = [ Brand.count, Team.count, User.count, Customer.count, CustomerIdentity.count, QueueVersion.count ]

    Seeds::Synthetic.call(seed: 42)

    expect([ Brand.count, Team.count, User.count, Customer.count, CustomerIdentity.count, QueueVersion.count ]).to eq(counts)
  end

  it "sementes diferentes produzem clientes diferentes" do
    Seeds::Synthetic.call(seed: 42)
    first = snapshot[:identities]
    DatabaseCleaner.clean_with(:truncation)

    Seeds::Synthetic.call(seed: 7)

    expect(snapshot[:identities]).not_to eq(first)
  end

  it "RNF-25: não usa dados reais (e-mails .test em ASCII, telefones com DDD 00)" do
    Seeds::Synthetic.call(seed: 42)

    expect(User.pluck(:email)).to all(end_with(".test"))
    emails = CustomerIdentity.where(channel: "email").pluck(:external_id)
    expect(emails).to all(end_with(".test").and(match(/\A[\x21-\x7e]+\z/)))
    phones = CustomerIdentity.where(channel: "whatsapp").pluck(:external_id)
    expect(phones).to all(match(/\A\+5500\d{9}\z/))
  end

  it "RN-30 / 06 parâmetros: o bot tem capacidade própria, 1.000 por padrão" do
    Seeds::Synthetic.call(seed: 42)

    expect(User.find_by!(kind: "bot").capacity).to eq(1_000)
    expect(User.where(kind: "human").pluck(:capacity)).to all(eq(5))
  end

  it "RN-42: cada marca com o idioma da mensagem padrão (pt-BR na InfinitePay, inglês na JIM)" do
    Seeds::Synthetic.call(seed: 42)

    expect(Brand.order(:slug).pluck(:slug, :locale)).to eq([ %w[infinitepay pt-BR], %w[jim en] ])
  end
end
