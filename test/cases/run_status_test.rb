# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

# `enqueued` = the job is in the queue, `running` = a worker is executing it,
# at every re-enqueue; `started_at` is set once, at the first execution.
class ActiveJob::RunStatusTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class StepError < StandardError; end

  # Records the run's status as another connection would read it while a step runs.
  class RecordingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :seen, default: []

    before_step { seen << [current_step.name.to_s, Run.find_by!(active_job_id: job_id).status] }
  end

  class IsolatedJob < RecordingJob
    def perform
      step(:one) {}
      step(:two, isolated: true) {}
      step(:three) {}
    end
  end

  class IteratingJob < RecordingJob
    cattr_accessor :raise_at

    def perform
      step :iterate, start: 0 do |step|
        (step.cursor...5).each do |i|
          if i == raise_at
            self.raise_at = nil
            raise StepError, "boom"
          end
          step.advance!
        end
      end
    end
  end

  class RetryingJob < IteratingJob
    retry_on StepError, wait: 1.hour, attempts: 3
  end

  setup do
    Step.delete_all
    Run.delete_all
    RecordingJob.seen = []
    IteratingJob.raise_at = nil
  end

  test "an isolated step re-enqueues the job: enqueued between executions, running during" do
    IsolatedJob.perform_later
    run = Run.sole
    assert_equal "enqueued", run.status
    assert_nil run.started_at

    perform_enqueued_jobs
    run.reload
    assert_equal "enqueued", run.status
    assert_equal [["one", "running"]], RecordingJob.seen
    started_at = run.started_at
    assert_not_nil started_at
    enqueued_at = run.transitioned_at

    travel 1.minute do
      perform_enqueued_jobs
      run.reload
      assert_equal "enqueued", run.status
      assert_equal [["one", "running"], ["two", "running"]], RecordingJob.seen
      assert_equal started_at, run.started_at
      assert_operator run.transitioned_at, :>, enqueued_at
      assert_enqueued_jobs 1
    end

    travel 2.minutes do
      perform_enqueued_jobs
      run.reload
      assert_equal "completed", run.status
      assert_equal [["one", "running"], ["two", "running"], ["three", "running"]], RecordingJob.seen
      assert_equal started_at, run.started_at
      assert_enqueued_jobs 0
    end
  end

  test "a graceful stop re-enqueues the job as enqueued and the next execution runs it" do
    IteratingJob.perform_later

    interrupt_job_during_step(IteratingJob, :iterate, cursor: 2) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal "interrupted", Step.find_by!(run_id: run.id, attempt: 1).status
    enqueued_at = run.transitioned_at

    travel 1.minute do
      perform_enqueued_jobs
      run.reload
      assert_equal "completed", run.status
      assert_equal [["iterate", "running"], ["iterate", "running"]], RecordingJob.seen
      assert_operator run.transitioned_at, :>, enqueued_at
    end
  end

  test "a resume after an error with progress re-enqueues the job as enqueued" do
    IteratingJob.raise_at = 2
    IteratingJob.perform_later

    assert_enqueued_jobs(1) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal "failed", Step.find_by!(run_id: run.id, attempt: 1).status
    assert_nil run.error_class
    enqueued_at = run.transitioned_at

    travel 1.minute do
      assert_enqueued_jobs(0) { perform_enqueued_jobs }
      run.reload
      assert_equal "completed", run.status
      assert_equal 1, run.resumptions
      assert_operator run.transitioned_at, :>, enqueued_at
    end
  end

  test "retry_on with a wait re-enqueues the job as enqueued until the retry runs" do
    RetryingJob.raise_at = 2
    RetryingJob.perform_later

    assert_enqueued_jobs(1) { perform_enqueued_jobs }
    assert_operator queue_adapter.enqueued_jobs.sole[:at], :>, 50.minutes.from_now.to_f

    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal "failed", Step.find_by!(run_id: run.id, attempt: 1).status
    started_at = run.started_at
    enqueued_at = run.transitioned_at

    travel 1.hour do
      assert_enqueued_jobs(0) { perform_enqueued_jobs }
      run.reload
      assert_equal "completed", run.status
      assert_equal started_at, run.started_at
      assert_equal 1, run.resumptions # a retry that starts with progress is a resume to Continuation
      assert_operator run.transitioned_at, :>, enqueued_at
      assert_equal [["iterate", "running"], ["iterate", "running"]], RecordingJob.seen
    end
  end

  test "stuck_for reads an enqueued run by transitioned_at and a running run by last_heartbeat_at" do
    IsolatedJob.perform_later
    perform_enqueued_jobs
    run = Run.sole
    assert_equal "enqueued", run.status

    travel 2.hours do
      assert_equal [run.id], Run.stuck_for(1.hour).pluck(:id)

      run.update_columns(status: "running")
      assert_equal [run.id], Run.stuck_for(1.hour).pluck(:id)

      run.update_columns(last_heartbeat_at: Time.current)
      assert_equal [], Run.stuck_for(1.hour).pluck(:id)
    end
  end
end
