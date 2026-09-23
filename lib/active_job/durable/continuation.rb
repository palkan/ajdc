# frozen_string_literal: true

module ActiveJob
  module Durable
    # A continuation whose steps take a timer (`wait:` or `wait_until:`) and can
    # await a signal; the running step's options are `step_options`.
    class Continuation < ActiveJob::Continuation
      prepend ActiveJob::Continuation::Callbacks

      # The options of the running step (`isolated:`, `wait:`, `wait_until:`,
      # `await:`), `nil` between steps.
      attr_reader :step_options

      private

      def run_step(name, start:, isolated:, wait: nil, wait_until: nil, await: false, &block)
        @step_options = {isolated:, wait:, wait_until:, await:}
        super(name, start:, isolated:, &block)
      ensure
        @step_options = nil
      end
    end
  end
end
