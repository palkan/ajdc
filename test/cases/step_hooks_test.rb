# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

class ActiveJob::StepHooksTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class StepError < StandardError; end

  class LoggingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :log, default: []
  end

  class OrderedJob < LoggingJob
    before_step { log << "before block #{current_step.name}" }
    before_step { |job| job.class.log << "before job #{job.current_step.name}" }
    before_step :note_before
    around_step :time_step
    around_step do |job, body|
      log << "around block in #{job.current_step.name}"
      body.call
      log << "around block out #{current_step.name}"
    end
    after_step :note_after
    after_step { log << "after block #{current_step.name}" }

    def perform
      log << "outside #{current_step.inspect}"
      step(:one) { log << "body one" }
      step(:two) { log << "body two" }
    end

    private

    def note_before = log << "before #{current_step.name}"

    def time_step
      log << "around in #{current_step.name}"
      yield
      log << "around out #{current_step.name}"
    end

    def note_after = log << "after #{current_step.name}"
  end

  class ChildJob < OrderedJob
    before_step { log << "child before" }
  end

  class IteratingJob < LoggingJob
    before_step { log << "before #{current_step.name}" }
    after_step { log << "after #{current_step.name}" }

    def perform
      step(:one) {}
      step :two, start: 0 do |step|
        (step.cursor...3).each { step.advance! }
      end
    end
  end

  class HaltingJob < LoggingJob
    after_step { log << "after #{current_step.name}" }

    def perform
      step(:one) {}
      step(:two) { halt!(:stop) }
    end
  end

  class DiscardingJob < LoggingJob
    discard_on StepError

    after_step { log << "after #{current_step.name}" }

    def perform
      step(:one) {}
      step(:two) { raise StepError, "boom" }
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    LoggingJob.log = []
  end

  test "callbacks run like perform callbacks: before and around in order, after in reverse inside around" do
    OrderedJob.perform_now

    one = [
      "before block one", "before job one", "before one",
      "around in one", "around block in one", "body one", "after block one", "after one",
      "around block out one", "around out one"
    ]
    assert_equal ["outside nil"] + one + one.map { |line| line.sub("one", "two") }, LoggingJob.log
  end

  test "a subclass extends the parent's callback chain" do
    ChildJob.perform_now
    assert_equal 2, LoggingJob.log.count("child before")
    assert_equal 2, LoggingJob.log.count("before block one") + LoggingJob.log.count("before block two")

    LoggingJob.log = []
    OrderedJob.perform_now
    assert_equal 0, LoggingJob.log.count("child before")
  end

  test "callbacks do not run for the steps skipped on resume" do
    IteratingJob.perform_later

    interrupt_job_during_step(IteratingJob, :two, cursor: 1) { perform_enqueued_jobs }
    assert_equal ["before one", "after one", "before two"], LoggingJob.log

    perform_enqueued_jobs
    assert_equal ["before one", "after one", "before two", "before two", "after two"], LoggingJob.log
    assert_equal "completed", Run.sole.status
  end

  test "after_step does not run for a halted or a failed step" do
    HaltingJob.perform_now
    assert_equal ["after one"], LoggingJob.log
    assert_equal "halted", Run.sole.status

    LoggingJob.log = []
    DiscardingJob.perform_now
    assert_equal ["after one"], LoggingJob.log
  end
end
