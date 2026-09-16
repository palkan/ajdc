# frozen_string_literal: true

require "active_job/continuation/rescue_handlers_first"

module Ajdc # :nodoc:
  class Railtie < ::Rails::Railtie # :nodoc:
    initializer "ajdc.rescue_handlers_first" do
      ActiveSupport.on_load(:active_job_continuable) do
        prepend ActiveJob::Continuation::RescueHandlersFirst
      end
    end
  end
end
