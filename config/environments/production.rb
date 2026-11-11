require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }
  config.assume_ssl = ENV["ASSUME_SSL"] == "true"
  config.force_ssl = ENV["FORCE_SSL"] == "true"
  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]

  # Includes `web` so Docker Compose service-to-service HTTP calls (`http://web:3000`) pass HostAuthorization.
  config.hosts.concat(ENV.fetch("ALLOWED_HOSTS", "localhost,127.0.0.1,::1,web").split(",").map(&:strip))
end
