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
      queues: QueueVersion.order(:name).pluck(:name, :version, :ai_first),
      accounts: ProviderAccount.order(:slug).pluck(:slug, :channel, :phone_number_id),
      rulesets: RoutingRuleset.joins(:brand).order("brands.slug", :version).map { ruleset_by_names(_1) }
    }
  end

  # O conjunto com os nomes das filas no lugar dos ids, para comparar entre execuções.
  def ruleset_by_names(ruleset)
    names = HelpdeskQueue.where(brand_id: ruleset.brand_id).to_h { [ _1.id, _1.current_version.name ] }
    rules = ruleset.rules["rules"].map { _1.merge("queue_id" => names.fetch(_1["queue_id"])) }
    [ ruleset.brand.slug, ruleset.version, names.fetch(ruleset.default_queue_id), rules ]
  end

  it "cria marca, fila, cliente sintético e usuário bot (bloco 01)" do
    Seeds::Synthetic.call(seed: 42)

    expect(Brand.pluck(:slug)).to include("infinitepay", "jim")
    expect(User.where(kind: "bot")).to exist
    expect(HelpdeskQueue.where(is_default: true).count).to eq(Brand.count)
    expect(Customer.count).to be >= 1
    expect(HelpdeskQueue.all).to all(have_attributes(current_version: be_present))
  end

  it "RF-42, bloco 10: cada marca tem uma fila humana de escalas (Escalas N1), sem IA primeiro, na mesma equipe" do
    Seeds::Synthetic.call(seed: 42)

    Brand.find_each do |brand|
      queue = HelpdeskQueue.find_by!(brand:, escalation: true, active: true)
      expect(queue).to have_attributes(is_default: false)
      expect(queue.current_version).to have_attributes(name: "Escalas N1", ai_first: false)
      expect(queue.team).to eq(HelpdeskQueue.find_by!(brand:, is_default: true).team)
    end
  end

  describe "bloco 11: filas e conjunto de regras v1 de cada marca (RF-13 a RF-15, RN-16, ADR-003)" do
    before { Seeds::Synthetic.call(seed: 42) }

    def queue_named(brand, name)
      HelpdeskQueue.joins(:current_version).find_by!(brand:, queue_versions: { name: })
    end

    it "cria Repasses e Maquininha com IA primeiro e Crédito sem IA, ativas, na equipe da marca" do
      Brand.find_each do |brand|
        expect(queue_named(brand, "Repasses").current_version).to have_attributes(version: 1, ai_first: true)
        expect(queue_named(brand, "Maquininha").current_version).to have_attributes(version: 1, ai_first: true)
        expect(queue_named(brand, "Crédito").current_version).to have_attributes(version: 1, ai_first: false)
        expect(HelpdeskQueue.where(brand:)).to all(have_attributes(active: true))
      end
    end

    it "publica a versão 1 do conjunto, com fila padrão Geral e regras que exercitam E e OU" do
      Brand.find_each do |brand|
        ruleset = RoutingRuleset.current_for(brand)
        expect(ruleset).to have_attributes(version: 1, default_queue: queue_named(brand, "Geral"),
                                           created_by: User.find_by!(email: "supervisora@helpdesk.test"))
        expect(ruleset.rules["rules"].size).to be_between(3, 4)
        expect(ruleset.rules["rules"].map { _1["any"].size }.max).to be >= 2
        expect(ruleset.rules["rules"].flat_map { _1["any"] }.map { _1["all"].size }.max).to be >= 2
      end
    end

    it "roteia pelas regras do seed e cai na Geral quando nada casa, nas duas marcas" do
      Brand.find_each do |brand|
        route = ->(**attrs) { Routing::Evaluate.call(brand:, attributes: { "channel" => "whatsapp", "tags" => [], **attrs.stringify_keys }) }

        expect(route.call(category: "credito", priority: "critica").queue_name).to eq("Crédito")
        expect(route.call(category: "credito", priority: "baixa").queue_name).to eq("Geral")
        expect(route.call(category: "maquininha", priority: "media").queue_name).to eq("Maquininha")
        expect(route.call(category: "pix", priority: "media", tags: %w[urgente]).queue_name).to eq("Maquininha")
        expect(route.call(category: "repasses", priority: "media").queue_name).to eq("Repasses")
        expect(route.call(category: "outros", priority: "media")).to have_attributes(queue_name: "Geral", default: true)
      end
    end
  end

  it "ADR-019: cria uma conta de provedor por marca e canal, com o segredo local do simulador" do
    Seeds::Synthetic.call(seed: 42)

    expect(ProviderAccount.where(evaluation: false).order(:slug).pluck(:slug)).to eq(%w[
      infinitepay-chat-mock infinitepay-email-mock infinitepay-whatsapp-mock jim-chat-mock jim-email-mock jim-whatsapp-mock
    ])
    expect(ProviderAccount.find_by!(slug: "jim-chat-mock")).to have_attributes(brand: Brand.find_by!(slug: "jim"),
                                                                              secret: "dev-secret-jim-chat-mock")
    expect(ProviderAccount.where(channel: "whatsapp").pluck(:phone_number_id)).to all(be_present)
  end

  it "ADR-023, item 5: cria a conta de chat de eval de cada marca, inativa e marcada como eval" do
    Seeds::Synthetic.call(seed: 42)

    evals = ProviderAccount.where(evaluation: true).order(:slug)
    expect(evals.pluck(:slug, :channel, :active)).to eq([ [ "infinitepay-chat-eval", "chat", false ], [ "jim-chat-eval", "chat", false ] ])
    expect(evals.map { _1.brand.slug }).to eq(%w[infinitepay jim])
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
    counts = [ Brand.count, Team.count, User.count, Customer.count, CustomerIdentity.count, QueueVersion.count,
               ProviderAccount.count, HelpdeskQueue.count, RoutingRuleset.count ]

    Seeds::Synthetic.call(seed: 42)

    expect([ Brand.count, Team.count, User.count, Customer.count, CustomerIdentity.count, QueueVersion.count,
             ProviderAccount.count, HelpdeskQueue.count, RoutingRuleset.count ]).to eq(counts)
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

  describe "RN-05: cliente de chat verificado para a demonstração" do
    it "cada marca tem um cliente verificado com a identidade chat do account_id do simulador" do
      Seeds::Synthetic.call(seed: 42)

      expect(Seeds::Synthetic::CHAT_ACCOUNT_IDS).to eq("infinitepay" => "acc_infinitepay_000021", "jim" => "acc_jim_000021")
      Seeds::Synthetic::CHAT_ACCOUNT_IDS.each do |slug, account_id|
        identity = CustomerIdentity.find_by!(brand: Brand.find_by!(slug:), channel: "chat", external_id: account_id)
        expect(identity.customer).to have_attributes(verified: true, brand_id: identity.brand_id)
      end
    end

    it "é determinístico pela semente e não duplica ao rodar de novo" do
      Seeds::Synthetic.call(seed: 42)
      owner = CustomerIdentity.where(channel: "chat").order(:external_id).map { _1.customer.display_name }

      Seeds::Synthetic.call(seed: 42)
      expect(CustomerIdentity.where(channel: "chat").count).to eq(2)
      DatabaseCleaner.clean_with(:truncation)

      Seeds::Synthetic.call(seed: 42)
      expect(CustomerIdentity.where(channel: "chat").order(:external_id).map { _1.customer.display_name }).to eq(owner)
    end

    it "a mensagem do simulador pelo chat chega de um cliente verificado, e a de outra marca não o alcança" do
      Seeds::Synthetic.call(seed: 42)

      expect(ingest(brand: "infinitepay", identity: "acc_infinitepay_000021").ticket.customer.verified).to be(true)
      expect(ingest("my payout", brand: "jim", identity: "acc_jim_000021").ticket.customer.verified).to be(true)
      expect(ingest("my payout", brand: "jim", identity: "acc_infinitepay_000021").ticket.customer.verified).to be(false)
    end
  end

  it "RN-42: cada marca com o idioma da mensagem padrão (pt-BR na InfinitePay, inglês na JIM)" do
    Seeds::Synthetic.call(seed: 42)

    expect(Brand.order(:slug).pluck(:slug, :locale)).to eq([ %w[infinitepay pt-BR], %w[jim en] ])
  end
end
