FactoryBot.define do
  factory :brand do
    sequence(:slug) { |n| "marca-#{n}" }
    name { slug.titleize }
    locale { "pt-BR" }
    timezone { "America/Sao_Paulo" }

    trait :infinitepay do
      slug { "infinitepay" }
      name { "InfinitePay" }
    end

    trait :jim do
      slug { "jim" }
      name { "JIM" }
    end
  end

  factory :team do
    brand
    sequence(:name) { |n| "Equipe #{n}" }
  end

  factory :user do
    sequence(:name) { |n| "Analista #{n}" }
    sequence(:email) { |n| "analista#{n}@example.test" }
    kind { "human" }
    role { "analyst" }
    status { "offline" }
    capacity { 5 }

    trait :bot do
      name { "Agente de IA" }
      sequence(:email) { |n| "bot#{n}@example.test" }
      kind { "bot" }
      role { "agent" }
      status { "online" }
    end
  end

  factory :customer do
    brand
    display_name { "Cliente sintético" }
    verified { false }
  end

  factory :customer_identity do
    customer
    brand { customer.brand }
    channel { "whatsapp" }
    sequence(:external_id) { |n| "+55119990#{n.to_s.rjust(5, '0')}" }
  end

  factory :queue_record, class: "HelpdeskQueue" do
    team
    brand { team.brand }
    is_default { false }
    active { true }
  end
end

FactoryBot.define do
  # Conta de provedor de canal (07, seção 5.0). O segredo segue o padrão local do simulador.
  factory :provider_account do
    brand
    channel { "chat" }
    slug { "#{brand.slug}-#{channel}-mock" }
    secret { "dev-secret-#{slug}" }
    phone_number_id { channel == "whatsapp" ? "1000000000#{brand.id.to_s.rjust(5, '0')}" : nil }
    email_address { channel == "email" ? "suporte@#{brand.slug}.example" : nil }
    active { true }
  end
end
