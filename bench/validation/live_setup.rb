# Prepara uma marca sintética isolada para o roteiro visual, sem alterar as regras das marcas existentes.
# docker compose run --rm -v ./bench:/bench web bin/rails runner /bench/validation/live_setup.rb
abort "somente em development" unless Rails.env.development?
run = ENV.fetch("VALIDATION_RUN", Time.current.utc.strftime("%Y%m%d%H%M%S"))
abort "VALIDATION_RUN deve conter só dígitos" unless run.match?(/\A\d{1,20}\z/)
slug = "validacao-#{run}"
supervisor = User.find_by!(email: "supervisora@helpdesk.test")
brand = team = account = nil
ActiveRecord::Base.transaction do
  brand = Brand.create!(slug:, name: "Validação #{run}", locale: "pt-BR", timezone: "America/Sao_Paulo")
  team = Team.create!(brand:, name: "Operação sintética")
  bot = User.find_by!(kind: "bot", email: "agente-ia@helpdesk.test")
  [ supervisor, bot ].each { TeamMembership.create!(user: _1, team:) }
  default = HelpdeskQueue.create!(brand:, team:, is_default: true)
  default.publish_version!(name: "Geral de validação", ai_first: true, created_by: supervisor)
  escalation = HelpdeskQueue.create!(brand:, team:, escalation: true)
  escalation.publish_version!(name: "Escalas de validação", ai_first: false, created_by: supervisor)
  RoutingRuleset.publish!(brand:, rules: { "schema_version" => 1, "rules" => [] }, default_queue: default, created_by: supervisor)
  account = ProviderAccount.create!(brand:, channel: "chat", slug: "#{slug}-chat-mock", secret: "dev-secret-#{slug}-chat-mock")
end
puts JSON.generate(run:, brand: brand.slug, brand_id: brand.id, team_id: team.id, account: account.slug)
