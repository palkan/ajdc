# frozen_string_literal: true

require "test_helper"

class ActiveJob::Continuation::RescueHandlersFirstTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DoNotPerformEnqueuedJobs

  class StepError < StandardError; end

  # Raises StepError once, at cursor 3, after progress; records every item processed.
  class IteratingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob -- the dummy app has no ApplicationJob
    include ActiveJob::Continuable

    cattr_accessor :items, default: []
    cattr_accessor :raised, default: false

    def perform
      step :iterate, start: 0 do |step|
        (step.cursor...5).each do |i|
          if i == 3 && !self.class.raised
            self.class.raised = true
            raise StepError, "boom"
          end
          items << i
          step.advance!
        end
      end
    end
  end

  class DiscardingJob < IteratingJob
    cattr_accessor :discarded

    discard_on(StepError) { |_job, error| self.discarded = error }
  end

  class RetryingJob < IteratingJob
    retry_on StepError, wait: 0, attempts: 2
  end

  setup do
    [IteratingJob, DiscardingJob, RetryingJob].each { |job| job.items = [] and job.raised = false }
  end

  test "discard_on sees an error raised after progress instead of resuming" do
    DiscardingJob.discarded = nil
    DiscardingJob.perform_later

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    assert_kind_of StepError, DiscardingJob.discarded
    assert_equal [0, 1, 2], DiscardingJob.items
  end

  test "retry_on retries an error raised after progress, keeping the cursor" do
    RetryingJob.perform_later

    assert_enqueued_jobs(1, only: RetryingJob) { perform_enqueued_jobs }

    job = queue_adapter.enqueued_jobs.first
    assert_equal 1, job["executions"]
    assert_equal ["iterate", 3], job["continuation"]["current"]

    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    assert_equal [0, 1, 2, 3, 4], RetryingJob.items
  end

  test "an error without a handler is resumed as before" do
    IteratingJob.perform_later

    assert_enqueued_jobs(1, only: IteratingJob) { perform_enqueued_jobs }

    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    assert_equal [0, 1, 2, 3, 4], IteratingJob.items
  end
end
