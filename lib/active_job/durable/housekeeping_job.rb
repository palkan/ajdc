# frozen_string_literal: true

module ActiveJob
  module Durable
    # Deletes old terminal runs: one scheduled call to `ActiveJob::Durable.clean_up`.
    # Add it to your schedule, e.g., Solid Queue:
    #
    #   # config/recurring.yml
    #   durable_housekeeping:
    #     class: ActiveJob::Durable::HousekeepingJob
    #     schedule: every hour
    class HousekeepingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
      def perform = Durable.clean_up
    end
  end
end
