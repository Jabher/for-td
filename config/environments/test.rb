Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Rails defaults to `:rescuable` in test; `:all` routes unhandled faults through
  # `ApplicationController#render_unexpected_error` so integration tests verify the 500 JSON contract.
  config.action_dispatch.show_exceptions = :all
  config.consider_all_requests_local = false
  config.cache_store = :null_store

  # Disabled because the test suite connects as `ledger_runtime`, which lacks `schema_migrations`
  # and DDL privileges (`DB_ROLE=admin` prepares the test schema explicitly beforehand).
  config.active_record.maintain_test_schema = false

  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true
end
