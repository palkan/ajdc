# frozen_string_literal: true

require "active_job/continuable/configurable"
require "active_job/continuation/callbacks"

module ActiveJob
  module Continuable
    # = Step callbacks
    #
    # Callbacks around every step that runs (a step skipped on resume runs none),
    # with the semantics of `before_perform` and friends; the step is `current_step`.
    # `after_step` runs only when the step completes.
    #
    #   class ProcessImportJob < ApplicationJob
    #     include ActiveJob::Continuable::Callbacks
    #
    #     around_step :measure
    #     after_step { logger.info "#{current_step.name} done" }
    #   end
    module Callbacks
      extend ActiveSupport::Concern
      include Configurable

      included do
        define_callbacks :step, skip_after_callbacks_if_terminated: true

        unless continuation_class <= Continuation::Callbacks
          self.continuation_class = Class.new(continuation_class) do
            prepend Continuation::Callbacks

            set_temporary_name "#{superclass.name}(WithCallbacks)"
          end
        end
      end

      class_methods do
        def before_step(*filters, &blk) = set_callback(:step, :before, *filters, &blk)

        def after_step(*filters, &blk) = set_callback(:step, :after, *filters, &blk)

        def around_step(*filters, &blk) = set_callback(:step, :around, *filters, &blk)
      end

      # The `ActiveJob::Continuation::Step` that is running, `nil` between steps.
      def current_step = continuation.running_step
    end
  end
end
