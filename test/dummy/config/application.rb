# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_job/railtie"
require "active_record/railtie"

require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)
require "ajdc"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    config.active_record.strict_loading_by_default = true
  end
end
