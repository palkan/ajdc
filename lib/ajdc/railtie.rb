# frozen_string_literal: true

require "active_job/continuation/rescue_handlers_first"

module Ajdc # :nodoc:
  class Railtie < ::Rails::Railtie # :nodoc:
    # Every option is an `ActiveJob::Durable` setting:
    #
    #   config.active_job_durable.connects_to = { database: { writing: :durable } }
    #   config.active_job_durable.keep_terminal_runs_for = 30.days
    config.active_job_durable = ActiveSupport::OrderedOptions.new

    # After the config initializers, so that an initializer can set them too.
    initializer "ajdc.config", after: :load_config_initializers do |app|
      app.config.active_job_durable.each { |name, value| ActiveJob::Durable.public_send(:"#{name}=", value) }
    end

    initializer "ajdc.rescue_handlers_first" do
      ActiveSupport.on_load(:active_job_continuable) do
        prepend ActiveJob::Continuation::RescueHandlersFirst
      end
    end
  end
end
