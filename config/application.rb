require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module TaxdomeTestTask
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])
    config.api_only = true

    # `schema.rb` drops SQL views (`public.firms`), `SECURITY DEFINER` PL/pgSQL functions
    # (`public.post_bulk_payments`), `CHECK` constraints, and immutability triggers.
    config.active_record.schema_format = :sql
  end
end
