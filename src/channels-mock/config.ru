require_relative "app"
# Falha inicial do provedor do chat, para experimentos sem clicar na tela (CHAT_PROVIDER_FAULT, README).
ChannelsMock::Faults.configure_from(ENV)
run ChannelsMock::App.freeze.app
