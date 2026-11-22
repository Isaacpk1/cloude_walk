require_relative "app"
# Falha inicial do provedor do chat, para experimentos sem clicar na tela (CHAT_PROVIDER_FAULT, README).
ChannelsMock::Faults.configure_from(ENV)
# Redis de controle do perfil do agente mock (AGENT_CONTROL_REDIS_URL; vazio desliga o seletor).
ChannelsMock::AgentProfile.configure_from(ENV)
run ChannelsMock::App.freeze.app
