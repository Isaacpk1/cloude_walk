# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# RN-51: identificadores do cliente e conteúdo das mensagens não vão para o log.
# Regex exatas para não esconder campos como `context` ou `account_version`.
Rails.application.config.filter_parameters += [
  /\Aaccount_id\z/, /\Acustomer_ref\z/, /\Atext\z/, /\Abody\z/, /\Afrom\z/, /\Ato\z/, /\Achannel_identity\z/
]
