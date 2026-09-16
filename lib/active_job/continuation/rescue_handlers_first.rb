# frozen_string_literal: true

require "active_job/continuation"

module ActiveJob
  class Continuation
    # = Rescue handlers first
    #
    # Continuable's +continue+ rescues any StandardError raised after the job made
    # progress and resumes the job, so +discard_on+, +retry_on+ and +rescue_from+
    # never see it. Prepended to ActiveJob::Continuable, this module gives the
    # job's own handlers precedence: when a handler exists for the error,
    # +resume_job+ re-raises it, and +perform_now+ runs the handler as it would
    # for any other job. Errors without a handler are resumed as before, and a
    # Continuation::Interrupt is never an error.
    module RescueHandlersFirst
      private

      # Rails 8.1 passes the error-resume exception as +{exception: e}+; main
      # passes it positionally. The argument goes to +super+ unchanged.
      def resume_job(exception)
        error = exception.is_a?(Hash) ? exception[:exception] : exception
        raise error if !error.is_a?(Continuation::Interrupt) && handler_for_rescue(error)

        super
      end
    end
  end
end
