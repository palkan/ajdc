# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

class ActiveJob::TimersTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step
  WakeJob = ActiveJob::Durable::WakeJob

  class StepError < StandardError; end

  class LicenseLifecycleJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    unique_by :license, on_conflict: :replace

    def perform(license)
      @license = license
      step :remind, wait_until: license.expires_at - 2.weeks
      step :expire, wait_until: license.expires_at
      step :revoke, wait: 2.weeks
    end

    private

    def remind = JobBuffer.add("remind:#{@license.id}")

    def expire = @license.expired!.then { JobBuffer.add("expire:#{@license.id}") }

    def revoke = @license.revoke!.then { JobBuffer.add("revoke:#{@license.id}") }
  end

  class IncinerationJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    unique_by :account

    def perform(account)
      step :incinerate, wait: 30.days do
        account.update!(state: "incinerated")
      end
    end
  end

  class LazyJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :evaluations, default: 0

    def perform(license)
      step(:one) { JobBuffer.add(:one) }
      step :remind, wait_until: -> { self.evaluations += 1 and license.expires_at - 2.weeks } do
        JobBuffer.add(:remind)
      end
      step :revoke, wait: -> { self.evaluations += 1 and 2.weeks } do
        JobBuffer.add(:revoke)
      end
    end
  end

  class BothJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform = step(:one, wait: 1.day, wait_until: 1.day.from_now) {}
  end

  class FlakyReminderJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :failed, default: false

    def perform(license)
      step :remind, wait_until: license.expires_at - 2.weeks, start: 0 do |step|
        %w[a b c][step.cursor..].each do |item|
          JobBuffer.add(item)
          step.set! step.cursor + 1
          raise StepError, "boom" if item == "b" && !failed && (self.failed = true)
        end
      end
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    License.delete_all
    LazyJob.evaluations = 0
    FlakyReminderJob.failed = false
    @now = Time.current.change(usec: 0)
    travel_to @now
    @license = License.create!(expires_at: @now + 30.days)
  end

  teardown { travel_back }

  test "wait_until: parks the run until the clock wakes it, step after step" do
    LicenseLifecycleJob.perform_later(@license)
    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "waiting", run.status
    assert run.live?
    assert_equal @now + 16.days, run.wake_at
    assert_equal "remind", run.current_step
    assert_equal [], run.completed_steps
    assert_equal run.id, run.parked_job["durable_run_id"]
    assert_equal "licenses/#{@license.id}", run.active_key
    assert_not_nil run.transitioned_at
    assert_equal 0, Step.count
    assert_equal [], JobBuffer.values
    assert_equal [run.id], LicenseLifecycleJob.workflow_runs.waiting.at_step(:remind).pluck(:id)

    travel 15.days
    assert_equal 0, Run.wake_due
    assert_enqueued_jobs 0

    travel 1.day
    ActiveJob::Durable.wake_up_due
    assert_equal "enqueued", run.reload.status
    assert_equal @now + 16.days, run.wake_at # kept until the step starts
    assert_equal "remind", run.current_step
    assert_enqueued_jobs 1

    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    run.reload
    assert_equal ["remind:#{@license.id}"], JobBuffer.values
    assert_equal "waiting", run.status
    assert_equal @license.expires_at, run.wake_at
    assert_equal "expire", run.current_step
    assert_equal ["remind"], run.completed_steps
    assert_equal [["remind", "completed"]], run.steps.map { |step| [step.name, step.status] }
    assert_equal 0, run.resumptions

    travel 14.days
    perform_enqueued_jobs { ActiveJob::Durable.wake_up_due }
    run.reload
    assert_equal "expired", @license.reload.state
    assert_equal "waiting", run.status
    assert_equal "revoke", run.current_step
    assert_equal Step.find_by!(name: "expire").finished_at + 2.weeks, run.wake_at
    assert_equal @now + 44.days, run.wake_at

    travel 14.days
    perform_enqueued_jobs { ActiveJob::Durable.wake_up_due }
    run.reload
    assert_equal "completed", run.status
    assert_equal "revoked", @license.reload.state
    assert_nil run.wake_at
    assert_nil run.active_key
    assert_nil run.parked_job
    assert_equal %w[remind expire revoke], run.completed_steps
    assert_equal 0, run.resumptions
    assert_equal ["remind:#{@license.id}", "expire:#{@license.id}", "revoke:#{@license.id}"], JobBuffer.values
    assert_enqueued_jobs 0
  end

  test "a target in the past runs the step at once" do
    @license.update!(expires_at: @now - 1.day)
    perform_enqueued_jobs { LicenseLifecycleJob.perform_later(@license) }

    run = Run.sole
    assert_equal ["remind:#{@license.id}", "expire:#{@license.id}"], JobBuffer.values
    assert_equal "waiting", run.status
    assert_equal "revoke", run.current_step
    assert_equal @now + 2.weeks, run.wake_at
  end

  test "a moved wait_until: target re-arms on wake" do
    perform_enqueued_jobs { LicenseLifecycleJob.perform_later(@license) }
    run = Run.sole
    assert_equal @now + 16.days, run.wake_at

    travel 16.days
    @license.update!(expires_at: @license.expires_at + 1.week) # renewed before the clock ticked
    perform_enqueued_jobs { assert_equal 1, ActiveJob::Durable.wake_up_due }
    run.reload

    assert_equal [], JobBuffer.values
    assert_equal "waiting", run.status
    assert_equal @now + 23.days, run.wake_at
    assert_equal "remind", run.current_step
    assert_equal 0, Step.count
    assert_equal 0, run.resumptions

    travel 7.days
    perform_enqueued_jobs { ActiveJob::Durable.wake_up_due }
    assert_equal ["remind:#{@license.id}"], JobBuffer.values
    assert_equal "expire", run.reload.current_step
  end

  test "wake_up ends the wait now" do
    perform_enqueued_jobs { LicenseLifecycleJob.perform_later(@license) }
    run = Run.sole

    assert_same run, run.wake_up

    assert_equal "enqueued", run.status
    assert_equal @now + 16.days, run.wake_at
    assert_equal({"remind" => nil}, run.pending_signals)
    assert_equal run.id, run.parked_job["durable_run_id"]
    assert_enqueued_jobs 1

    perform_enqueued_jobs
    run.reload
    assert_equal ["remind:#{@license.id}"], JobBuffer.values
    assert_equal({}, run.pending_signals)
    assert_equal "waiting", run.status
    assert_equal "expire", run.current_step
    assert_equal @license.expires_at, run.wake_at
  end

  test "wake_up raises NotWaiting unless the run is waiting" do
    LicenseLifecycleJob.perform_later(@license)
    run = Run.sole
    assert_equal "enqueued", run.status

    error = assert_raises(ActiveJob::Durable::NotWaiting) { run.wake_up }
    assert_match(/Run #{run.id} is enqueued/, error.message)

    perform_enqueued_jobs
    stale = Run.find(run.id)
    run.wake_up
    assert_raises(ActiveJob::Durable::NotWaiting) { stale.wake_up }
    assert_enqueued_jobs 1

    run.cancel!
    assert_raises(ActiveJob::Durable::NotWaiting) { run.wake_up }
  end

  test "wait: counts from the run's start on a first step and a cancel! stops the clock" do
    account = Card.create!(title: "Account")
    IncinerationJob.perform_later(account)
    assert_equal false, IncinerationJob.perform_later(account)
    travel 1.hour # in the queue
    perform_enqueued_jobs

    run = Run.sole
    assert_equal "waiting", run.status
    assert_equal run.started_at + 30.days, run.wake_at
    assert_equal @now + 1.hour + 30.days, run.wake_at
    assert_equal false, IncinerationJob.perform_later(account)

    run.cancel! # reactivated
    assert_kind_of IncinerationJob, IncinerationJob.perform_later(account)

    travel 31.days
    assert_equal 0, Run.wake_due
    assert_enqueued_jobs 1 # the new run's first execution, not a wake
    assert_nil account.reload.state
  end

  test "the clock wakes each due run once" do
    other = License.create!(expires_at: @now + 60.days)
    perform_enqueued_jobs do
      LicenseLifecycleJob.perform_later(@license)
      LicenseLifecycleJob.perform_later(other)
    end
    assert_equal %w[waiting waiting], Run.pluck(:status)

    travel 16.days
    assert_equal 1, ActiveJob::Durable.wake_up_due
    assert_equal 0, ActiveJob::Durable.wake_up_due
    assert_equal 0, WakeJob.perform_now # the scheduled job is the same call
    assert_enqueued_jobs 1
    assert_equal [@now + 46.days], Run.due.or(Run.waiting).pluck(:wake_at)
  end

  test "a callable target is evaluated when the step is reached" do
    perform_enqueued_jobs { LazyJob.perform_later(@license) }

    run = Run.sole
    assert_equal [:one], JobBuffer.values
    assert_equal 1, LazyJob.evaluations
    assert_equal @now + 16.days, run.wake_at

    perform_enqueued_jobs { run.wake_up }
    run.reload
    assert_equal [:one, :remind], JobBuffer.values
    assert_equal 2, LazyJob.evaluations # the consumed wake skips the target, the next step evaluates its own
    assert_equal "revoke", run.current_step
    assert_equal @now + 2.weeks, run.wake_at
  end

  test "a resumed step does not wait again" do
    perform_enqueued_jobs { FlakyReminderJob.perform_later(@license) }
    run = Run.sole
    assert_equal "waiting", run.status

    run.wake_up
    perform_enqueued_jobs # fails at "b" after progress: Continuation resumes
    run.reload
    assert_equal %w[a b], JobBuffer.values
    assert_equal "enqueued", run.status
    assert_equal "remind", run.current_step
    assert_enqueued_jobs 1

    perform_enqueued_jobs
    run.reload
    assert_equal "completed", run.status
    assert_equal %w[a b c], JobBuffer.values
    assert_equal [[1, "failed", 2], [2, "completed", 3]], run.steps.map { |step| [step.attempt, step.status, step.cursor] }
  end

  test "wait: and wait_until: together raise" do
    error = assert_raises(ArgumentError) { BothJob.perform_now }
    assert_equal "Step 'one' takes wait: or wait_until:, not both", error.message
  end

  test "a parked run is stuck only once its wake time is overdue" do
    perform_enqueued_jobs { LicenseLifecycleJob.perform_later(@license) }
    run = Run.sole

    travel 15.days
    assert_equal [], Run.stuck_for(1.hour).pluck(:id)

    travel 1.day + 2.hours
    assert_equal [run.id], Run.stuck_for(1.hour).pluck(:id)
  end
end
