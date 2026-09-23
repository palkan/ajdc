# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"

class ActiveJob::UniquenessTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run

  class ImportJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    unique_by :card

    def perform(card, format = nil)
      @card = card
      step :check
      step :process, isolated: true
    end

    private

    def check = JobBuffer.add("check:#{@card.title}")

    def process
    end
  end

  class RejectingJob < ImportJob
    unique_by :card, on_conflict: :reject
  end

  class ReplacingJob < ImportJob
    unique_by :card, on_conflict: :replace
  end

  class HaltingJob < ImportJob
    def check = halt!(:storage)
  end

  class FailingJob < ImportJob
    def check = raise("boom")
  end

  # `key` and `active_key` derive independently.
  class StyledJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    identified_by :card
    unique_by :card, :style

    def perform(card, style: nil)
      step(:one) {}
    end
  end

  class PlainJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(card)
      step(:one) {}
    end
  end

  # Misses the live run on its first look, so the unique index has to decide.
  module RacingLookup
    def durable_live_run(...)
      @looked ||= 0
      ((@looked += 1) == 1) ? nil : super
    end
  end

  class RacingSkipJob < ImportJob
    include RacingLookup
  end

  class RacingReplaceJob < ReplacingJob
    include RacingLookup
  end

  setup do
    ActiveJob::Durable::Step.delete_all
    Run.delete_all
    @card = Card.create!(title: "Hello")
    @other_card = Card.create!(title: "World")
  end

  test "on_conflict: :skip enqueues nothing and returns false" do
    first = ImportJob.perform_later(@card)
    assert_equal false, ImportJob.perform_later(@card)
    assert_equal false, ImportJob.perform_later(@card, "csv")
    ImportJob.perform_later(@other_card)

    assert_enqueued_jobs 2
    assert_equal 2, Run.count
    run = ImportJob.workflow_runs.for(@card).sole
    assert_equal first.job_id, run.active_job_id
    assert_equal "cards/#{@card.id}", run.key
    assert_equal run.key, run.active_key
  end

  test "a finished run frees the key" do
    perform_enqueued_jobs { ImportJob.perform_later(@card) }

    run = Run.sole
    assert_equal "completed", run.status
    assert_nil run.active_key

    ImportJob.perform_later(@card)
    assert_equal 2, ImportJob.workflow_runs.for(@card).count
  end

  test "a halted run keeps the key until it is cancelled" do
    perform_enqueued_jobs { HaltingJob.perform_later(@card) }
    halted = Run.sole
    assert_equal "halted", halted.status
    assert_equal "cards/#{@card.id}", halted.active_key
    assert_equal false, HaltingJob.perform_later(@card)

    halted.cancel!
    assert_kind_of HaltingJob, HaltingJob.perform_later(@card)
    assert_equal 2, Run.count
  end

  test "a failed run keeps the key" do
    FailingJob.perform_later(@card)
    assert_raises(RuntimeError) { perform_enqueued_jobs }
    failed = Run.sole
    assert_equal "failed", failed.status
    assert_equal "cards/#{@card.id}", failed.active_key
    assert_equal false, FailingJob.perform_later(@card)
  end

  test "on_conflict: :reject raises RunAlreadyExists" do
    RejectingJob.perform_later(@card)

    error = assert_raises(ActiveJob::Durable::RunAlreadyExists) { RejectingJob.perform_later(@card) }
    assert_equal Run.sole, error.run
    assert_match(/cards\/#{@card.id}/, error.message)
    assert_enqueued_jobs 1
    assert_equal 1, Run.count
  end

  test "on_conflict: :replace cancels the live run and starts a new one" do
    first = ReplacingJob.perform_later(@card)
    second = ReplacingJob.perform_later(@card)

    assert_enqueued_jobs 2
    runs = ReplacingJob.workflow_runs.for(@card).reorder(:id)
    assert_equal %w[cancelled enqueued], runs.map(&:status)
    assert_equal [first.job_id, second.job_id], runs.map(&:active_job_id)
    assert_equal [nil, "cards/#{@card.id}"], runs.map(&:active_key)

    perform_enqueued_jobs # the cancelled run's job performs nothing
    perform_enqueued_jobs
    assert_equal ["check:Hello"], JobBuffer.values
    assert_equal %w[cancelled completed], runs.reload.map(&:status)
  end

  test "perform_all_later jobs are checked at their first run" do
    ActiveJob.perform_all_later([ImportJob.new(@card), ImportJob.new(@card)])
    assert_equal 0, Run.count

    perform_enqueued_jobs
    assert_equal 1, Run.count
    assert_equal ["check:Hello"], JobBuffer.values

    ActiveJob.perform_all_later([RejectingJob.new(@other_card), RejectingJob.new(@other_card)])
    assert_raises(ActiveJob::Durable::RunAlreadyExists) { perform_enqueued_jobs }
    assert_equal 1, RejectingJob.workflow_runs.count
  end

  test "unique_by with identified_by" do
    StyledJob.perform_later(@card, style: "plain")
    StyledJob.perform_later(@card, style: "bold")
    assert_equal false, StyledJob.perform_later(@card, style: "plain")

    runs = StyledJob.workflow_runs.for(@card).reorder(:id)
    assert_equal ["cards/#{@card.id}"] * 2, runs.map(&:key)
    assert_equal ["cards/#{@card.id}:plain", "cards/#{@card.id}:bold"], runs.map(&:active_key)
  end

  test "workflow_key acts as a uniqueness key" do
    ImportJob.set(workflow_key: "import-42").perform_later(@card)
    assert_equal false, ImportJob.set(workflow_key: "import-42").perform_later(@other_card)

    run = Run.sole
    assert_equal "import-42", run.key
    assert_equal "import-42", run.active_key
  end

  test "without unique_by active_key is null" do
    PlainJob.perform_later(@card)
    PlainJob.perform_later(@card)

    assert_equal [nil, nil], Run.pluck(:active_key)
  end

  test "unique_by checks the names" do
    job_class = Class.new(ImportJob) do
      def perform(card, format = nil)
        super
      end

      unique_by :kind
    end
    error = assert_raises(ArgumentError) { job_class.perform_later(@card) }
    assert_equal "unknown perform identifier parameters [:kind] (perform has card, format)", error.message

    error = assert_raises(ArgumentError) { Class.new(ImportJob) { unique_by :card, on_conflict: :merge } }
    assert_match(/on_conflict/, error.message)
  end

  test "unique_by survives race conditions due to index" do
    Run.create!(job_class: RacingSkipJob.name, key: "cards/#{@card.id}", active_key: "cards/#{@card.id}",
      active_job_id: SecureRandom.uuid, arguments: [], status: "enqueued", transitioned_at: Time.current)
    assert_equal false, RacingSkipJob.perform_later(@card)
    assert_equal 1, Run.count

    Run.update_all(job_class: RacingReplaceJob.name)
    RacingReplaceJob.perform_later(@card)
    assert_equal %w[cancelled enqueued], Run.order(:id).pluck(:status)
  end
end
