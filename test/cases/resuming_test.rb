# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

# `run.resume!` puts a `halted` or `failed` run back in the queue, in place: the
# step that stopped re-runs from its cursor as a new attempt, the earlier attempts
# keep their errors, and the manual resume is not one of Continuation's resumptions.
class ActiveJob::ResumingTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class InsufficientStorageError < StandardError; end

  class StepError < StandardError; end

  class DataImportJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

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

  class DiagnosticJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :checked, default: []
    cattr_accessor :websocket_ok, default: false

    after_step { checked << current_step.name }

    def perform(cable)
      @cable = cable
      step :provider_status, isolated: true
      step :websocket_status, isolated: true
      step :admin_api_status, isolated: true
    end

    private

    def provider_status
    end

    def websocket_status
      halt!(:websocket_failed) unless websocket_ok
    end

    def admin_api_status
    end
  end

  class AgentRunJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(chat)
      step :run do |step|
        until chat.done?
          chat.tick!
          halt!(:approval) if chat.needs_approval?
          step.checkpoint!
        end
      end
    end
  end

  # Raises an undeclared error before any progress until the card is ready.
  class FetchJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(card)
      step :fetch do
        raise StepError, "not ready" unless card.state == "ready"

        card.update!(verdict: "fetched")
      end
      step(:finish) { card.update!(state: "done") }
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    DataImportJob.imported = []
    DataImportJob.failure = nil
    DiagnosticJob.checked = []
    DiagnosticJob.websocket_ok = false
    @import = Card.create!(title: "Invoices")
  end

  test "resume! after halt_on re-runs the halted step from its cursor" do
    DataImportJob.failure = ["c", InsufficientStorageError]
    DataImportJob.perform_later(@import, %w[a b c d e])
    perform_enqueued_jobs

    run = Run.sole
    assert_equal "halted", run.status
    assert_equal %w[a b], DataImportJob.imported
    DataImportJob.imported = []

    assert_same run, run.resume!

    assert_equal "enqueued", run.status
    assert_nil run.error_class
    assert_nil run.error_message
    assert_nil run.halt_reason
    assert_nil run.finished_at
    assert_equal run.id, run.parked_job["durable_run_id"]
    assert_enqueued_jobs 1

    perform_enqueued_jobs
    run.reload

    assert_equal "completed", run.status
    assert_equal %w[c d e], DataImportJob.imported
    assert_nil run.parked_job
    assert_equal 0, run.resumptions
    assert_equal ["check", "process"], run.completed_steps
    assert_equal [
      ["check", 1, "completed", nil],
      ["process", 1, "halted", "ActiveJob::ResumingTest::InsufficientStorageError"],
      ["process", 2, "completed", nil]
    ], run.steps.map { |step| [step.name, step.attempt, step.status, step.error_class] }
    assert_equal [2, 5], run.steps.where(name: "process").pluck(:cursor)
  end

  test "resume! after halt! re-runs the halted step and the later steps follow" do
    cable = Card.create!(title: "Cable")
    DiagnosticJob.perform_later(cable)
    2.times { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "halted", run.status
    assert_equal "websocket_failed", run.halt_reason
    assert_equal 1, run.resumptions

    DiagnosticJob.websocket_ok = true
    run.resume!
    assert_nil run.halt_reason

    2.times { perform_enqueued_jobs } # websocket_status, then admin_api_status in its own execution
    run.reload

    assert_equal "completed", run.status
    assert_nil run.halt_reason
    assert_equal %i[provider_status websocket_status admin_api_status], DiagnosticJob.checked
    assert_equal 2, run.resumptions # the isolated steps, not the manual resume
    assert_equal [
      ["provider_status", 1, "completed"],
      ["websocket_status", 1, "halted"],
      ["websocket_status", 2, "completed"],
      ["admin_api_status", 1, "completed"]
    ], run.steps.map { |step| [step.name, step.attempt, step.status] }
    assert_enqueued_jobs 0
  end

  test "resume! after a halt mid-loop re-enters the loop step" do
    chat = Chat.create!(turn_limit: 5, approval_turn: 2)
    AgentRunJob.perform_later(chat)
    perform_enqueued_jobs

    run = Run.sole
    assert_equal "halted", run.status
    assert_equal 2, chat.reload.turns

    chat.approve!
    run.resume!
    perform_enqueued_jobs
    run.reload

    assert_equal "completed", run.status
    assert_equal 5, chat.reload.turns
    assert_equal [[1, "halted"], [2, "completed"]], run.steps.map { |step| [step.attempt, step.status] }
    assert_equal 0, run.resumptions
  end

  test "resume! after a failure runs the failed step again" do
    card = Card.create!(title: "Card", state: "pending")
    FetchJob.perform_later(card)
    assert_raises(StepError) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "failed", run.status
    assert_equal "ActiveJob::ResumingTest::StepError", run.error_class
    assert_not_nil run.finished_at
    assert_equal run.id, run.parked_job["durable_run_id"]

    card.update!(state: "ready")
    run.resume!

    assert_equal "enqueued", run.status
    assert_nil run.error_class
    assert_nil run.error_message
    assert_nil run.finished_at

    perform_enqueued_jobs
    run.reload

    assert_equal "completed", run.status
    assert_equal "done", card.reload.state
    assert_equal 0, run.resumptions
    assert_equal [
      ["fetch", 1, "failed", "ActiveJob::ResumingTest::StepError"],
      ["fetch", 2, "completed", nil],
      ["finish", 1, "completed", nil]
    ], run.steps.map { |step| [step.name, step.attempt, step.status, step.error_class] }
  end

  test "resume! raises NotResumable unless the run is halted or failed" do
    card = Card.create!(title: "Card", state: "ready")
    FetchJob.perform_later(card)
    perform_enqueued_jobs
    run = Run.sole
    assert_equal "completed", run.status

    error = assert_raises(ActiveJob::Durable::NotResumable) { run.resume! }
    assert_match(/Run #{run.id} is completed/, error.message)

    %w[running enqueued].each do |status|
      run.update_columns(status:)
      assert_raises(ActiveJob::Durable::NotResumable) { run.resume! }
    end
    assert_enqueued_jobs 0
  end

  test "a second resume! of the same run raises" do
    DataImportJob.failure = ["c", InsufficientStorageError]
    DataImportJob.perform_later(@import, %w[a b c])
    perform_enqueued_jobs

    run = Run.sole
    stale = Run.find(run.id)
    run.resume!

    assert_raises(ActiveJob::Durable::NotResumable) { stale.resume! }
    assert_enqueued_jobs 1
  end

  test "resume! inside a transaction enqueues after the commit" do
    DataImportJob.failure = ["c", InsufficientStorageError]
    DataImportJob.perform_later(@import, %w[a b c])
    perform_enqueued_jobs
    run = Run.sole

    ActiveRecord::Base.transaction do
      run.resume!
      assert_equal "enqueued", run.status
      assert_enqueued_jobs 0
    end

    assert_enqueued_jobs 1
    perform_enqueued_jobs
    assert_equal "completed", run.reload.status
  end
end
