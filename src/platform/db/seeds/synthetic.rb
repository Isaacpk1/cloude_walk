# Gerador de dados sintéticos reprodutível por semente (RF-61, RNF-25).
# Nenhum dado real: e-mails no domínio reservado .test (RFC 2606) e telefones
# com DDD 00, que não existe no Brasil.
#
#   Seeds::Synthetic.call(seed: 42, customers_per_brand: 5)
#
# Idempotente: rodar de novo com a mesma semente não duplica registros.
require "faker"

module Seeds
  class Synthetic
    BRANDS = [
      { slug: "infinitepay", name: "InfinitePay", locale: "pt-BR" },
      { slug: "jim", name: "JIM", locale: "en" } # RN-42
    ].freeze
    # Capacidade padrão do agente de IA (06, parâmetros). As réplicas do agent-mock dão a vazão.
    BOT_CAPACITY = 1_000
    # Número de WhatsApp sintético por marca (07, seção 5.0). Ligado à URL da conta.
    WHATSAPP_PHONE_NUMBER_IDS = { "infinitepay" => "100000000000001", "jim" => "100000000000002" }.freeze
    # RN-05: conta do cliente no chat do app (account_id do webhook) do primeiro cliente, verificado, de cada
    # marca. A da InfinitePay é a que o simulador (channels-mock) traz preenchida; a da JIM segue o mesmo
    # formato. Sem ela, quem entra pelo chat chega como cliente não verificado e a IA pede identificação.
    CHAT_ACCOUNT_IDS = { "infinitepay" => "acc_infinitepay_000021", "jim" => "acc_jim_000021" }.freeze
    # Bloco 11 (RF-13): filas temáticas além da Geral e da Escalas N1. Crédito é só humana (sem IA primeiro).
    ROUTING_QUEUES = { "Repasses" => true, "Crédito" => false, "Maquininha" => true }.freeze
    # Bloco 11: conjunto v1 de cada marca (ADR-003, RN-16). Cada regra: [nome, fila, [[campo, op, valor], ...] por
    # grupo]. A primeira exercita o E, a segunda o OU; o resto cai na fila padrão Geral.
    ROUTING_RULES = [
      [ "Crédito com prioridade alta ou crítica", "Crédito",
        [ [ %w[category eq credito], [ "priority", "in", %w[alta critica] ] ] ] ],
      [ "Maquininha ou urgente", "Maquininha", [ [ %w[category eq maquininha] ], [ %w[tags contains urgente] ] ] ],
      [ "Repasses", "Repasses", [ [ %w[category eq repasses] ] ] ]
    ].freeze

    def self.call(...) = new(...).call

    def initialize(seed: 42, customers_per_brand: 5)
      @seed = seed
      @customers_per_brand = customers_per_brand
    end

    def call
      Faker::Config.random = Random.new(@seed)
      Faker::Config.locale = "pt-BR"

      ActiveRecord::Base.transaction do
        bot = upsert_user(name: "Agente de IA", email: "agente-ia@helpdesk.test", kind: "bot", role: "agent", status: "online",
                        capacity: BOT_CAPACITY)
        supervisor = upsert_user(name: "Supervisora Sintética", email: "supervisora@helpdesk.test", role: "supervisor")

        BRANDS.each do |attrs|
          brand = Brand.find_or_create_by!(slug: attrs[:slug]) { _1.assign_attributes(attrs) }
          team = Team.find_or_create_by!(brand:, name: "Suporte N1")
          [ bot, supervisor, *analysts_for(brand) ].each { |user| TeamMembership.find_or_create_by!(user:, team:) }
          default_queue = default_queue_for(brand, team, created_by: supervisor)
          escalation_queue_for(brand, team, created_by: supervisor)
          routing_for(brand, team, default_queue, created_by: supervisor)
          provider_accounts_for(brand)
          ProviderAccount.evaluation_for!(brand, "chat") # ADR-023, item 5: conta do eval, inativa
          customers_for(brand)
        end
      end
    ensure
      Faker::Config.random = nil
    end

    private

    def upsert_user(email:, **attrs)
      User.find_or_create_by!(email:) { |user| user.assign_attributes(attrs) }
    end

    # ADR-019: uma conta por canal. O segredo segue a regra do channels-mock: variável
    # PROVIDER_SECRET_<CONTA> ou, no ambiente local, "dev-secret-<conta>".
    def provider_accounts_for(brand)
      CustomerIdentity::CHANNELS.each do |channel|
        slug = "#{brand.slug}-#{channel}-mock"
        ProviderAccount.find_or_create_by!(slug:) do |account|
          account.assign_attributes(
            brand:, channel:, phone_number_id: (WHATSAPP_PHONE_NUMBER_IDS.fetch(brand.slug) if channel == "whatsapp"),
            secret: ENV.fetch("PROVIDER_SECRET_#{slug.upcase.tr('-', '_')}", "dev-secret-#{slug}")
          )
        end
      end
    end

    def analysts_for(brand)
      Array.new(2) do |i|
        upsert_user(name: "Analista #{i + 1} #{brand.name}", email: "analista#{i + 1}.#{brand.slug}@helpdesk.test")
      end
    end

    def default_queue_for(brand, team, created_by:)
      queue = HelpdeskQueue.find_or_create_by!(brand:, is_default: true) { _1.team = team }
      queue.publish_version!(name: "Geral", ai_first: true, created_by:) if queue.current_version.nil?
      queue
    end

    # RF-42 (bloco 10): a fila humana para onde o handoff vai até o roteamento por regras (bloco 11).
    def escalation_queue_for(brand, team, created_by:)
      queue = HelpdeskQueue.find_or_create_by!(brand:, escalation: true, active: true) { _1.team = team }
      queue.publish_version!(name: "Escalas N1", ai_first: false, created_by:) if queue.current_version.nil?
      queue
    end

    # Bloco 11: filas por nome da versão e a versão 1 do conjunto, só se a marca ainda não tem conjunto. Rodar de
    # novo não cria fila nem versão; um conjunto que o supervisor já publicou não é tocado (RN-20).
    def routing_for(brand, team, default_queue, created_by:)
      queues = ROUTING_QUEUES.to_h do |name, ai_first|
        queue = HelpdeskQueue.joins(:current_version).find_by(brand:, queue_versions: { name: })
        queue ||= HelpdeskQueue.create!(brand:, team:).tap { _1.publish_version!(name:, ai_first:, created_by:) }
        [ name, queue ]
      end
      return if RoutingRuleset.exists?(brand_id: brand.id)

      rules = ROUTING_RULES.map do |name, queue, groups|
        { "name" => name, "queue_id" => queues.fetch(queue).id,
          "any" => groups.map { |conds| { "all" => conds.map { |f, op, v| { "field" => f, "op" => op, "value" => v } } } } }
      end
      RoutingRuleset.publish!(brand:, rules: { "schema_version" => 1, "rules" => rules }, default_queue:, created_by:)
    end

    def customers_for(brand)
      Array.new(@customers_per_brand) do |i|
        name = Faker::Name.name
        phone = format("+5500%09d", Faker::Number.unique.number(digits: 9))
        local = I18n.transliterate(Faker::Internet.username(specifier: name, separators: %w[.]))
        email = "#{local}.#{i}@#{brand.slug}.example.test"

        identity = CustomerIdentity.find_by(brand:, channel: "whatsapp", external_id: phone)
        customer = identity&.customer || Customer.create!(brand:, display_name: name, verified: i.even?).tap do |created|
          created.identities.create!(brand:, channel: "whatsapp", external_id: phone)
          created.identities.create!(brand:, channel: "email", external_id: email)
        end
        chat_identity_for(customer) if i.zero?
        customer
      end
    ensure
      Faker::Number.unique.clear
    end

    # O primeiro cliente é verificado (i.even?). Se a conta já pertence a outro cliente (ex.: criado pela
    # ingestão antes do seed), não muda o dono: o seed não mexe em dados que não criou.
    def chat_identity_for(customer)
      attrs = { brand_id: customer.brand_id, channel: "chat", external_id: CHAT_ACCOUNT_IDS.fetch(customer.brand.slug) }
      return if CustomerIdentity.exists?(attrs)

      customer.identities.create!(attrs)
    end
  end
end
