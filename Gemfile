# frozen_string_literal: true

source "https://rubygems.org"

gem "debug", platform: :mri unless ENV["CI"] == "true"

gem "rails-hyperdrive", require: false

gem "sqlite3"

gemspec

eval_gemfile "gemfiles/rubocop.gemfile"

local_gemfile = File.join(__dir__, ENV.fetch("LOCAL_GEMFILE", "Gemfile.local"))

if File.exist?(local_gemfile)
  eval_gemfile(local_gemfile)
else
  gem "rails", "~> 8.1"
end
