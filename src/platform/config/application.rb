require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Platform
  class Application < Rails::Application
    # structure.sql guarda triggers e FKs compostas que o schema.rb não representa (RN-20, invariante 8).
    config.active_record.schema_format = :sql
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # ADR-005: jobs no Sidekiq (filas e pesos em config/sidekiq.yml). Nos testes, adaptador :test.
    config.active_job.queue_adapter = :sidekiq

    # ADR-019: segredos das contas de canal criptografados no banco (Active Record Encryption).
    # As chaves vêm do ambiente. Os valores padrão só existem para desenvolvimento e testes.
    encryption = config.active_record.encryption
    dev_key = ->(name) { Rails.env.production? ? ENV.fetch(name) : ENV.fetch(name, "dev-only-#{name.downcase}") }
    encryption.primary_key = dev_key.("AR_ENCRYPTION_PRIMARY_KEY")
    encryption.deterministic_key = dev_key.("AR_ENCRYPTION_DETERMINISTIC_KEY")
    encryption.key_derivation_salt = dev_key.("AR_ENCRYPTION_KEY_DERIVATION_SALT")
  end
end
