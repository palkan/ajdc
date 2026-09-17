# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

class ActiveJob::HaltingTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class IntegrityError < StandardError; end

  class InsufficientStorageError < StandardError; end

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

  class DiagnosticJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    cattr_accessor :checked, default: []

    after_step :record

    def perform(cable)
      @cable = cable
      step :provider_status, isolated: true
      step :websocket_status, isolated: true
      step :admin_api_status, isolated: true
    end

    private

    def provider_status
    end

    def websocket_status = halt!(:websocket_failed)

    def admin_api_status
    end

    def record = checked << current_step.name
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

  class OutsideStepJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform
      halt!(:early)
      step(:one) {}
    end
  end

  setup do
    Step.delete_all
    Run.delete_all
    DataImportJob.imported = []
    DataImportJob.failure = nil
    DiagnosticJob.checked = []
    @import = Card.create!(title: "Invoices")
  end

  test "halt_on parks the run at the failing step with its cursor" do
    DataImportJob.failure = ["c", InsufficientStorageError]
    DataImportJob.perform_later(@import, %w[a b c d e])

    assert_enqueued_jobs(0) { assert_nothing_raised { perform_enqueued_jobs } }

    run = Run.sole
    assert_equal "halted", run.status
    assert run.attention?
    assert_equal "process", run.current_step
    assert_equal ["check"], run.completed_steps
    assert_equal "ActiveJob::HaltingTest::InsufficientStorageError", run.error_class
    assert_equal "no room for c", run.error_message
    assert_nil run.halt_reason
    assert_nil run.finished_at
    assert_not_nil run.transitioned_at
    assert_equal run.id, run.parked_job["durable_run_id"]

    step = Step.find_by!(run_id: run.id, name: "process")
    assert_equal "halted", step.status
    assert_equal 2, step.cursor
    assert_equal "ActiveJob::HaltingTest::InsufficientStorageError", step.error_class
    assert_equal %w[a b], DataImportJob.imported
    assert_equal "checked", @import.reload.state
  end

  test "discard_on still wins after progress" do
    DataImportJob.failure = ["c", IntegrityError]
    DataImportJob.perform_later(@import, %w[a b c d e])

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "discarded", run.status
    assert_equal "failed", Step.find_by!(run_id: run.id, name: "process").status
    assert_equal %w[a b], DataImportJob.imported
  end

  test "halt! parks the run with a reason and the later steps never run" do
    cable = Card.create!(title: "Cable")
    DiagnosticJob.perform_later(cable)

    2.times { perform_enqueued_jobs } # provider_status, then websocket_status in its own execution

    run = Run.sole
    assert_equal "halted", run.status
    assert_equal "websocket_failed", run.halt_reason
    assert_nil run.error_class
    assert_nil run.error_message
    assert_equal "websocket_status", run.current_step
    assert_equal ["provider_status"], run.completed_steps
    assert_equal 1, run.resumptions
    assert_equal [:provider_status], DiagnosticJob.checked
    assert_equal [["provider_status", "completed"], ["websocket_status", "halted"]],
      run.steps.map { |step| [step.name, step.status] }
    assert_enqueued_jobs 0
  end

  test "halt! mid-loop keeps the step attempt with no cursor" do
    chat = Chat.create!(turn_limit: 5, approval_turn: 2)
    AgentRunJob.perform_later(chat)

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    run = Run.sole
    assert_equal "halted", run.status
    assert_equal "approval", run.halt_reason
    assert_equal "run", run.current_step
    assert_equal 2, chat.reload.turns
    assert_equal [[1, "halted", nil]], run.steps.map { |step| [step.attempt, step.status, step.cursor] }
  end

  test "halt! outside a step raises" do
    error = assert_raises(ArgumentError) { OutsideStepJob.perform_now }

    assert_equal "halt! must be called inside a step", error.message
  end

  test "a job whose run is terminal performs nothing" do
    DataImportJob.perform_later(@import, %w[a b c])
    run = Run.sole
    run.update_columns(status: "cancelled")

    perform_enqueued_jobs

    assert_performed_jobs 1
    assert_equal "cancelled", run.reload.status
    assert_nil run.started_at
    assert_equal 0, Step.count
    assert_equal [], DataImportJob.imported
  end
end
