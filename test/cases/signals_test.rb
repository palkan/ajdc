# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

class ActiveJob::SignalsTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class StepError < StandardError; end

  class BulkImportJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    after_step { JobBuffer.add([current_step.name, current_step.cursor]) }

    def perform(import)
      @import = import
      await :confirmation, wait: 10.minutes
      return import.update!(state: "dropped") unless import.state == "confirmed"

      step(:apply) { import.update!(state: "applied") }
    end

    private

    def confirmation(signal) = @import.update!(state: signal ? "confirmed" : "missed")
  end

  class CardGenerationJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :signal_during_moderation

    def perform(card)
      @card = card
      step :moderate, isolated: true
      await :review, wait: 1.hour if card.verdict == "unsure"
      step :generate unless card.verdict == "rejected"
    end

    private

    def moderate
      JobBuffer.add(:moderate)
      Run.find_by!(active_job_id: job_id).wake_up(:review, signal_during_moderation) if signal_during_moderation
    end

    def review(verdict)
      halt!(:not_now) if verdict == "later"
      @card.update!(verdict: verdict || "rejected")
    end

    def generate = JobBuffer.add(:generate)
  end

  class ApprovalJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(card)
      await(:approval) { |decision| card.update!(state: decision) }
      step(:publish) { JobBuffer.add(:publish) }
    end
  end

  class FlakyJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :failed, default: false

    def perform
      await :number
    end

    private

    def number(value)
      JobBuffer.add(value)
      return if failed

      self.failed = true
      raise StepError, "boom"
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    CardGenerationJob.signal_during_moderation = nil
    FlakyJob.failed = false
    @now = Time.current.change(usec: 0)
    travel_to @now
    @import = Card.create!(title: "Import", state: "parsed")
  end

  teardown { travel_back }

  test "await parks the run until the signal arrives" do
    BulkImportJob.perform_later(@import)
    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "awaiting", run.status
    assert run.live?
    assert_equal "confirmation", run.current_step
    assert_equal @now + 10.minutes, run.wake_at
    assert_equal [], run.completed_steps
    assert_equal({}, run.pending_signals)
    assert_equal run.id, run.parked_job["durable_run_id"]
    assert_equal 0, Step.count
    assert_equal [run.id], BulkImportJob.workflow_runs.awaiting.at_step(:confirmation).pluck(:id)
    assert_equal "parsed", @import.reload.state

    assert_same run, run.wake_up(:confirmation, true)

    assert_equal "enqueued", run.status
    assert_equal({"confirmation" => true}, run.pending_signals)
    assert_enqueued_jobs 1

    perform_enqueued_jobs
    run.reload
    assert_equal "completed", run.status
    assert_equal "applied", @import.reload.state
    assert_equal({}, run.pending_signals)
    assert_nil run.wake_at
    assert_equal %w[confirmation apply], run.completed_steps
    assert_equal [["confirmation", "completed", true], ["apply", "completed", nil]],
      run.steps.map { |step| [step.name, step.status, step.cursor] }
    assert_equal [[:confirmation, nil], [:apply, nil]], JobBuffer.values # the Step object keeps its start cursor
    assert_equal 0, run.resumptions
  end

  test "the deadline wakes the await with nil" do
    perform_enqueued_jobs { BulkImportJob.perform_later(@import) }
    run = Run.sole

    travel 9.minutes
    assert_equal 0, ActiveJob::Durable.wake_up_due

    travel 1.minute
    perform_enqueued_jobs { assert_equal 1, ActiveJob::Durable.wake_up_due }
    run.reload

    assert_equal "completed", run.status
    assert_equal "dropped", @import.reload.state
    assert_equal ["confirmation"], run.completed_steps
    assert_equal [["confirmation", "completed", nil]], run.steps.map { |step| [step.name, step.status, step.cursor] }
  end

  test "a signal racing the clock is not lost" do
    perform_enqueued_jobs { BulkImportJob.perform_later(@import) }
    run = Run.sole

    travel 10.minutes
    ActiveJob::Durable.wake_up_due
    run.wake_up(:confirmation, true) # enqueued already: buffered, not a second wake

    assert_enqueued_jobs 1
    perform_enqueued_jobs
    assert_equal "applied", @import.reload.state
  end

  test "a signal sent before the await is reached is consumed on the spot" do
    BulkImportJob.perform_later(@import)
    run = Run.sole
    assert_equal "enqueued", run.status

    run.wake_up(:confirmation, "maybe")
    run.wake_up(:confirmation, "yes") # overwrites

    assert_equal "enqueued", run.status
    assert_equal({"confirmation" => "yes"}, run.pending_signals)
    assert_enqueued_jobs 1

    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    run.reload
    assert_equal "completed", run.status
    assert_equal({}, run.pending_signals)
    assert_equal [["confirmation", "yes"], ["apply", nil]], run.steps.map { |step| [step.name, step.cursor] }
  end

  test "a signal sent during an earlier step waits for the await" do
    card = Card.create!(title: "Card", verdict: "unsure")
    CardGenerationJob.signal_during_moderation = "approved"
    CardGenerationJob.perform_later(card)
    perform_enqueued_jobs # moderate, isolated

    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal({"review" => "approved"}, run.pending_signals)
    assert_enqueued_jobs 1

    perform_enqueued_jobs
    run.reload
    assert_equal "completed", run.status
    assert_equal "approved", card.reload.verdict
    assert_equal [:moderate, :generate], JobBuffer.values
    assert_equal %w[moderate review generate], run.completed_steps
  end

  test "an await line that is not reached leaves nothing behind" do
    card = Card.create!(title: "Card", verdict: "ok")
    perform_enqueued_jobs { CardGenerationJob.perform_later(card) }

    run = Run.sole
    assert_equal "completed", run.status
    assert_equal %w[moderate generate], run.completed_steps
  end

  test "wake_up with no name gives the await nil" do
    card = Card.create!(title: "Card", verdict: "unsure")
    perform_enqueued_jobs { CardGenerationJob.perform_later(card) }
    run = Run.sole
    assert_equal "awaiting", run.status

    run.wake_up
    assert_equal({"review" => nil}, run.pending_signals)
    perform_enqueued_jobs

    assert_equal "completed", run.reload.status
    assert_equal "rejected", card.reload.verdict
    assert_equal [:moderate], JobBuffer.values
  end

  test "an await without a deadline waits for the signal alone" do
    card = Card.create!(title: "Card")
    perform_enqueued_jobs { ApprovalJob.perform_later(card) }
    run = Run.sole
    assert_equal "awaiting", run.status
    assert_nil run.wake_at

    travel 1.year
    assert_equal 0, ActiveJob::Durable.wake_up_due
    assert_equal [], Run.stuck_for(1.day).pluck(:id)

    perform_enqueued_jobs { run.wake_up(:approval, "approved") }
    assert_equal "completed", run.reload.status
    assert_equal "approved", card.reload.state
    assert_equal [:publish], JobBuffer.values
  end

  test "a halted handler awaits again on resume, with a fresh deadline" do
    card = Card.create!(title: "Card", verdict: "unsure")
    perform_enqueued_jobs { CardGenerationJob.perform_later(card) }
    run = Run.sole

    perform_enqueued_jobs { run.wake_up(:review, "later") }
    run.reload
    assert_equal "halted", run.status
    assert_equal "not_now", run.halt_reason
    assert_equal [["review", 1, "halted", "later"]], run.steps.where(name: "review").map { |step| [step.name, step.attempt, step.status, step.cursor] }

    travel 2.hours
    run.resume!
    assert_enqueued_jobs(0) { perform_enqueued_jobs }
    run.reload
    assert_equal "awaiting", run.status
    assert_equal @now + 3.hours, run.wake_at
    assert_equal 1, run.steps.where(name: "review").count

    perform_enqueued_jobs { run.wake_up(:review, "approved") }
    run.reload
    assert_equal "completed", run.status
    assert_equal "approved", card.reload.verdict
    assert_equal [[1, "halted", "later"], [2, "completed", "approved"]],
      run.steps.where(name: "review").map { |step| [step.attempt, step.status, step.cursor] }
    assert_equal [:moderate, :generate], JobBuffer.values
  end

  test "a failed handler replays the signal on resume" do
    perform_enqueued_jobs { FlakyJob.perform_later }
    run = Run.sole
    assert_equal "awaiting", run.status

    run.wake_up(:number, 42)
    assert_raises(StepError) { perform_enqueued_jobs }
    run.reload
    assert_equal "failed", run.status
    assert_equal [[1, "failed", 42]], run.steps.map { |step| [step.attempt, step.status, step.cursor] }

    perform_enqueued_jobs { run.resume! }
    run.reload
    assert_equal "completed", run.status
    assert_equal [42, 42], JobBuffer.values
    assert_equal [[1, "failed", 42], [2, "completed", 42]], run.steps.map { |step| [step.attempt, step.status, step.cursor] }
  end

  test "wake_up raises unless the run can take the signal" do
    BulkImportJob.perform_later(@import)
    run = Run.sole
    assert_raises(ActiveJob::Durable::NotWaiting) { run.wake_up } # enqueued: nothing is parked

    perform_enqueued_jobs
    perform_enqueued_jobs { run.wake_up(:confirmation, true) }
    assert_equal "completed", run.reload.status
    error = assert_raises(ActiveJob::Durable::NotLive) { run.wake_up(:confirmation, true) }
    assert_match(/Run #{run.id} is completed/, error.message)

    run.update_columns(status: "halted")
    assert_raises(ActiveJob::Durable::NotLive) { run.wake_up(:confirmation, true) }
    run.update_columns(status: "cancelled")
    assert_raises(ActiveJob::Durable::NotWaiting) { run.wake_up }
    assert_enqueued_jobs 0
  end

  test "wake_up inside a transaction enqueues after the commit" do
    perform_enqueued_jobs { BulkImportJob.perform_later(@import) }
    run = Run.sole

    ActiveRecord::Base.transaction do
      run.wake_up(:confirmation, false)
      assert_equal "enqueued", run.status
      raise ActiveRecord::Rollback
    end
    assert_equal "awaiting", run.reload.status
    assert_equal({}, run.pending_signals)
    assert_enqueued_jobs 0

    ActiveRecord::Base.transaction do
      run.wake_up(:confirmation, true)
      assert_equal "enqueued", run.status
      assert_enqueued_jobs 0
    end
    assert_enqueued_jobs 1
    perform_enqueued_jobs
    assert_equal "applied", @import.reload.state
  end
end
