# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"
require "active_support/core_ext/object/with"

class ActiveJob::StepLifecycleTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class StepError < StandardError; end

  class IteratingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :raised, default: false

    def perform(*)
      step :iterate, start: 0 do |step|
        (step.cursor...5).each do |i|
          if i == 2 && !self.class.raised
            self.class.raised = true
            raise StepError, "boom"
          end
          step.advance!
        end
      end
    end
  end

  class DiscardingJob < IteratingJob
    discard_on StepError
  end

  class RetryingJob < IteratingJob
    retry_on StepError, wait: 0, attempts: 2
  end

  class FailingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    self.resume_errors_after_advancing = false

    def perform
      step(:one) {}
      step(:two) { raise StepError, "boom" }
    end
  end

  class IsolatedJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform
      step(:one) {}
      step(:two, isolated: true) {}
      step(:three) {}
    end
  end

  class TaggedCardJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    identified_by :card

    def perform(card, tag)
      step(:one) {}
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    IteratingJob.raised = false
  end

  test "discard_on after progress discards the run and fails the step" do
    DiscardingJob.perform_later

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "discarded", run.status
    step = Step.find_by!(run_id: run.id, name: "iterate")
    assert_equal "failed", step.status
    assert_equal "ActiveJob::StepLifecycleTest::StepError", step.error_class
  end

  test "an unhandled error fails the run and keeps the current step" do
    FailingJob.perform_later

    assert_raises(StepError) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "failed", run.status
    assert_equal "ActiveJob::StepLifecycleTest::StepError", run.error_class
    assert_equal "boom", run.error_message
    assert_equal "two", run.current_step
    assert_equal ["one"], run.completed_steps
  end

  test "retry_on after progress re-enqueues the run and completes on the retry" do
    RetryingJob.perform_later

    assert_enqueued_jobs(1) { perform_enqueued_jobs }
    assert_equal "enqueued", Run.sole.status

    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    assert_equal "completed", Run.sole.status
  end

  test "an isolated step runs in its own execution" do
    perform_enqueued_jobs { IsolatedJob.perform_later }

    assert_performed_jobs 3
    assert_enqueued_jobs 0
    run = Run.sole
    assert_equal "completed", run.status
    assert_equal 2, run.resumptions
    steps = Step.where(run_id: run.id).order(:position)
    assert_equal %w[one two three], steps.map(&:name)
    assert_equal [false, true, false], steps.map(&:isolated)
    assert_equal %w[completed completed completed], steps.map(&:status)
  end

  test "the run keeps its first started_at, sets finished_at and counts resumes" do
    IteratingJob.raised = true # never raise
    IteratingJob.perform_later

    interrupt_job_during_step(IteratingJob, :iterate, cursor: 1) { perform_enqueued_jobs }
    run = Run.sole
    started_at = run.started_at
    assert_not_nil started_at
    assert_nil run.finished_at

    travel 1.minute do
      interrupt_job_during_step(IteratingJob, :iterate, cursor: 3) { perform_enqueued_jobs }
      perform_enqueued_jobs
    end

    run.reload
    assert_equal "completed", run.status
    assert_equal started_at, run.started_at
    assert_not_nil run.finished_at
    assert_equal 2, run.resumptions
  end

  test "runs of the same record share a key whatever the other arguments" do
    card = Card.create!(title: "Hello")

    TaggedCardJob.perform_later(card, "foo")
    TaggedCardJob.perform_later(card, "bar")

    assert_equal 2, Run.count
    assert_equal ["cards/#{card.id}"], Run.distinct.pluck(:key)
  end
end
