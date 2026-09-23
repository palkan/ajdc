# frozen_string_literal: true

require "active_job/continuation"

module ActiveJob
  class Continuation
    # Runs the job's step callbacks around each step's body. Prepended to the
    # job's `continuation_class` by `ActiveJob::Continuable::Callbacks`.
    module Callbacks
      # The step that is running, `nil` between steps.
      def running_step = (current if running_step?)

      private

      def instrumenting_step(step, &block) = super { job.run_callbacks(:step, &block) }
    end
  end
end
