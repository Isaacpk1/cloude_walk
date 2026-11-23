# Bloco 14 (ADR-024): os request specs do painel entram logados como supervisor de todas as marcas existentes na
# primeira requisição ao painel, salvo os marcados com `:anonymous` ou os que chamam `sign_in(user)` antes.
module PanelLogin
  PASSWORD = "senha-sintetica-1".freeze
  OPEN_PATHS = %r{\A/(webhooks|entrar|sair|up)}

  # Entra como `user` pelo login de verdade (a sessão é a do Rails).
  def sign_in(user)
    user.update_columns(password_digest: BCrypt::Password.create(PASSWORD, cost: 4)) if user.password_digest.blank?
    @signed_in = true
    post login_path, params: { email: user.email, password: PASSWORD }
  end

  # Supervisor que vê todas as marcas existentes: uma equipe por marca.
  def default_supervisor
    user = create(:user, role: "supervisor", name: "Supervisão de testes")
    Brand.find_each { |brand| TeamMembership.create!(user:, team: Team.find_by(brand:) || create(:team, brand:)) }
    user
  end

  %i[get post patch put delete head].each do |verb|
    define_method(verb) do |path, **kwargs|
      unless @signed_in || RSpec.current_example.metadata[:anonymous] || path.to_s.match?(OPEN_PATHS)
        @signed_in = true
        sign_in(default_supervisor)
      end
      super(path, **kwargs)
    end
  end
end

# Bloco 14: os system specs (Capybara) entram pelo formulário de login, como um supervisor.
module PanelFormLogin
  def log_in_as_supervisor
    user = create(:user, role: "supervisor", email: "chefe@helpdesk.test", password: PanelLogin::PASSWORD)
    Brand.find_each { |brand| TeamMembership.create!(user:, team: Team.find_by(brand:) || create(:team, brand:)) }
    visit "/entrar"
    fill_in "E-mail", with: user.email
    fill_in "Senha", with: PanelLogin::PASSWORD
    click_button "Entrar"
    user
  end
end

RSpec.configure do |config|
  config.include PanelFormLogin, type: :system
  config.include PanelLogin, type: :request
end
