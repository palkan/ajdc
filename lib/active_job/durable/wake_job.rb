# frozen_string_literal: true

module ActiveJob
  module Durable
    # The clock for `wait:`, `wait_until:` and `await` deadlines: one scheduled call to
    # `ActiveJob::Durable.wake_up_due`. Add it to your schedule, e.g., Solid Queue:
    #
    #   # config/recurring.yml
    #   durable_wake:
    #     class: ActiveJob::Durable::WakeJob
    #     schedule: every minute
    class WakeJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
      def perform = Durable.wake_up_due
    end
  end
end
