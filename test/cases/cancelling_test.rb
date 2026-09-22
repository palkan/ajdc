# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

# `run.cancel!` ends a run from outside: one status-guarded row update that never
# touches the queue. A queued message for a cancelled run performs nothing; a
# running job stops at its next checkpoint or step boundary.
class ActiveJob::CancellingTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class IntegrityError < StandardError; end

  class InsufficientStorageError < StandardError; end

  class StepError < StandardError; end

  class DataImportJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    discard_on IntegrityError
    halt_on InsufficientStorageError

    identified_by :import

    cattr_accessor :imported, default: []
    cattr_accessor :failure

    def perform(import, items)
      @import = import
      step :check
      step :process, start: 0 do |step|
        items[step.cursor..].each do |item|
          raise_once!(item)
          imported << item
          step.set! step.cursor + 1
        end
      end
    end

    private

    def check = @import.update!(state: "checked")

    def raise_once!(item)
      failing_item, error = failure
      return unless item == failing_item

      self.failure = nil
      raise error, "no room for #{item}"
    end
  end

  # Raises before any progress until the card is ready.
  class FetchJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(card)
      step :fetch do
        raise StepError, "not ready" unless card.state == "ready"

        card.update!(verdict: "fetched")
      end
    end
  end

  # Another process cancels the run while the export loop runs: after
  # `cancel_after` items, or together with an error at `fail_at`.
  class ExportJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :exported, default: []
    cattr_accessor :cancel_after
    cattr_accessor :fail_at

    def perform(items)
      step :export, start: 0 do |step|
        items[step.cursor..].each do |item|
          exported << item
          Run.find_by!(active_job_id: job_id).cancel! if exported.size == cancel_after
          raise StepError, "boom at #{item}" if item == fail_at

          step.set! step.cursor + 1
        end
      end
    end
  end

  class RecordingJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :ran, default: []

    def perform
      step(:one) { ran << :one }
      step(:two) { ran << :two }
    end
  end

  class IsolatedJob < RecordingJob
    def perform
      step(:one, isolated: true) { ran << :one }
      step(:two, isolated: true) { ran << :two }
    end
  end

  class AfterStepCancelJob < RecordingJob
    after_step { Run.find_by!(active_job_id: job_id).cancel! if current_step.name == :one }
  end

  class BeforePerformCancelJob < RecordingJob
    before_perform { Run.find_by!(active_job_id: job_id).cancel! }
  end

  class TailCancelJob < RecordingJob
    def perform
      super
      Run.find_by!(active_job_id: job_id).cancel!
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    DataImportJob.imported = []
    DataImportJob.failure = nil
    ExportJob.exported = []
    ExportJob.cancel_after = nil
    ExportJob.fail_at = nil
    RecordingJob.ran = []
    @import = Card.create!(title: "Invoices")
  end

  test "cancel! on an enqueued run ends it and the queued message performs nothing" do
    DataImportJob.perform_later(@import, %w[a b c])
    run = Run.sole
    run.update_columns(active_key: run.key)
    assert_equal "enqueued", run.status

    assert_same run, run.cancel!

    assert_equal "cancelled", run.status
    assert run.terminal?
    assert_nil run.active_key
    assert_nil run.parked_job
    assert_not_nil run.finished_at
    assert_not_nil run.transitioned_at
    assert_enqueued_jobs 1
    row = run.attributes

    assert_nothing_raised { perform_enqueued_jobs }

    assert_performed_jobs 1
    assert_enqueued_jobs 0
    assert_equal row, Run.find(run.id).attributes
    assert_equal 0, Step.count
    assert_equal [], DataImportJob.imported
    assert_nil @import.reload.state
  end

  test "cancel! on a halted run ends it and resume! raises" do
    DataImportJob.failure = ["b", InsufficientStorageError]
    perform_enqueued_jobs { DataImportJob.perform_later(@import, %w[a b c]) }
    run = Run.sole
    assert_equal "halted", run.status

    run.cancel!

    assert_equal "cancelled", run.status
    assert_nil run.parked_job
    assert_not_nil run.finished_at
    assert_equal "process", run.current_step
    assert_equal [["check", "completed"], ["process", "halted"]], run.steps.map { |step| [step.name, step.status] }
    assert_raises(ActiveJob::Durable::NotResumable) { run.resume! }
    assert_enqueued_jobs 0
  end

  test "cancel! on a failed run ends it and resume! raises" do
    card = Card.create!(title: "Card", state: "pending")
    FetchJob.perform_later(card)
    assert_raises(StepError) { perform_enqueued_jobs }
    run = Run.sole
    assert_equal "failed", run.status

    run.cancel!

    assert_equal "cancelled", run.status
    assert_nil run.parked_job
    assert_equal "ActiveJob::CancellingTest::StepError", run.error_class
    assert_raises(ActiveJob::Durable::NotResumable) { run.resume! }
    assert_enqueued_jobs 0
  end

  test "cancel! inside a transaction follows the transaction" do
    DataImportJob.perform_later(@import, %w[a b c])
    run = Run.sole

    ActiveRecord::Base.transaction do
      run.cancel!
      assert_equal "cancelled", run.status
      raise ActiveRecord::Rollback
    end
    assert_equal "enqueued", run.reload.status
    assert run.live?

    ActiveRecord::Base.transaction { run.cancel! }
    assert_equal "cancelled", run.reload.status
  end

  test "a running job stops at the checkpoint after a cancel!" do
    ExportJob.cancel_after = 2
    ExportJob.perform_later(%w[a b c d e])

    assert_nothing_raised { perform_enqueued_jobs }

    assert_enqueued_jobs 0
    assert_equal %w[a b], ExportJob.exported
    run = Run.sole
    assert_equal "cancelled", run.status
    assert_equal "export", run.current_step
    assert_equal [], run.completed_steps
    assert_not_nil run.finished_at
    assert_nil run.parked_job
    step = Step.sole
    assert_equal "cancelled", step.status
    assert_equal 2, step.cursor
    assert_nil step.error_class
    assert_not_nil step.finished_at
  end

  test "an error after a cancel! is not resumed" do
    ExportJob.cancel_after = 2
    ExportJob.fail_at = "b"
    ExportJob.perform_later(%w[a b c])

    assert_nothing_raised { perform_enqueued_jobs }

    assert_enqueued_jobs 0
    assert_equal %w[a b], ExportJob.exported
    run = Run.sole
    assert_equal "cancelled", run.status
    assert_nil run.error_class
    assert_equal [["failed", 1, "ActiveJob::CancellingTest::StepError"]],
      run.steps.map { |step| [step.status, step.cursor, step.error_class] }
  end

  test "cancel! between isolated steps makes the next execution a no-op" do
    IsolatedJob.perform_later
    perform_enqueued_jobs
    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal [:one], RecordingJob.ran
    assert_enqueued_jobs 1

    run.cancel!
    assert_nothing_raised { perform_enqueued_jobs }

    assert_enqueued_jobs 0
    assert_equal [:one], RecordingJob.ran
    assert_equal "cancelled", run.reload.status
    assert_equal ["one"], run.completed_steps
    assert_equal [["one", "completed"]], run.steps.map { |step| [step.name, step.status] }
  end

  test "cancel! from after_step stops before the next step" do
    AfterStepCancelJob.perform_later

    assert_nothing_raised { perform_enqueued_jobs }

    assert_enqueued_jobs 0
    assert_equal [:one], RecordingJob.ran
    run = Run.sole
    assert_equal "cancelled", run.status
    assert_equal [], run.completed_steps
    assert_equal "one", run.current_step
    assert_equal [["one", "cancelled"]], run.steps.map { |step| [step.name, step.status] }
  end

  test "cancel! before the first step stops before any step" do
    BeforePerformCancelJob.perform_later

    assert_nothing_raised { perform_enqueued_jobs }

    assert_enqueued_jobs 0
    assert_equal [], RecordingJob.ran
    run = Run.sole
    assert_equal "cancelled", run.status
    assert_not_nil run.started_at
    assert_equal 0, Step.count
  end

  test "cancel! after the last step leaves the run cancelled" do
    perform_enqueued_jobs { TailCancelJob.perform_later }

    assert_equal %i[one two], RecordingJob.ran
    run = Run.sole
    assert_equal "cancelled", run.status
    assert_equal %w[one two], run.completed_steps
    assert_equal %w[completed completed], run.steps.map(&:status)
  end

  test "cancel! on a terminal run raises NotCancellable" do
    card = Card.create!(title: "Card", state: "ready")
    perform_enqueued_jobs { FetchJob.perform_later(card) }
    completed = Run.sole
    assert_equal "completed", completed.status

    error = assert_raises(ActiveJob::Durable::NotCancellable) { completed.cancel! }
    assert_match(/Run #{completed.id} is completed/, error.message)

    DataImportJob.failure = ["b", IntegrityError]
    perform_enqueued_jobs { DataImportJob.perform_later(@import, %w[a b c]) }
    discarded = Run.where.not(id: completed.id).sole
    assert_equal "discarded", discarded.status
    assert_raises(ActiveJob::Durable::NotCancellable) { discarded.cancel! }

    discarded.update_columns(status: "enqueued")
    stale = Run.find(discarded.id)
    discarded.cancel!
    error = assert_raises(ActiveJob::Durable::NotCancellable) { stale.cancel! }
    assert_match(/is cancelled/, error.message)
    assert_raises(ActiveJob::Durable::NotCancellable) { discarded.cancel! }
  end
end
