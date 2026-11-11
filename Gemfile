source "https://rubygems.org"

ruby "4.0.9"

gem "rails", "~> 8.1.4", ">= 8.1.4.1"
gem "pg", "~> 1.7"
gem "puma", "~> 8.0"

# Windows/JRuby lack OS zoneinfo files.
gem "tzinfo-data", "~> 1.2025", platforms: %i[ windows jruby ]

gem "bootsnap", "~> 1.26", require: false

group :development, :test do
  gem "debug", "~> 1.11", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", "~> 0.9", require: false
  gem "brakeman", "~> 8.1", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
end
