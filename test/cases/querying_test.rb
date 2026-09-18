# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"
require "active_support/core_ext/object/with"

class ActiveJob::QueryingTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run

  class BaseJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    def perform(*, **)
      step(:one) {}
      step(:two) {}
    end
  end

  # Default workflow_key made of every argument (positional and kwargs)
  class CardJob < BaseJob
    def perform(card, tag = nil, style: nil, size: nil)
      super
    end
  end

  class OtherJob < BaseJob
    def perform(card)
      super
    end
  end

  class IdentifiedCardJob < BaseJob
    identified_by :card

    def perform(card, tag = nil, style: nil)
      super
    end
  end

  class ExportJob < BaseJob
    identified_by { |*args, **kwargs| [args.first, kwargs.fetch(:format, :csv), :export] }

    def perform(card, format: :csv)
      super
    end
  end

  class FixedKeyJob < BaseJob
    identified_by { "x" }
  end

  # The block is not evaluated on the job: `arguments` is a job method.
  class SelfReferencingJob < BaseJob
    identified_by { |*| arguments.first }

    def perform(card)
      super
    end
  end

  # `identified_by` before `perform`: the parameter check waits for the first key.
  class LateCheckedJob < BaseJob
    identified_by :kind

    def perform(card)
      super
    end
  end

  class StyleJob < BaseJob
    identified_by :style

    def perform(card, style:)
      super
    end
  end

  setup do
    ActiveJob::Durable::Step.delete_all
    Run.delete_all
    @card = Card.create!(title: "Hello")
    @other_card = Card.create!(title: "World")
  end

  test "workflow_runs returns this class's runs, newest first" do
    first = CardJob.perform_later(@card)
    OtherJob.perform_later(@card)
    second = CardJob.perform_later(@other_card)

    runs = CardJob.workflow_runs
    assert_equal 2, runs.count
    assert_equal [second.job_id, first.job_id], runs.map(&:active_job_id)
    assert_equal ["ActiveJob::QueryingTest::CardJob"], runs.map(&:job_class).uniq
  end

  test "for finds the runs started with the same arguments" do
    CardJob.perform_later(@card, "foo")
    CardJob.perform_later(@card, "bar")
    CardJob.perform_later(@other_card, "foo")

    assert_equal 1, CardJob.workflow_runs.for(@card, "foo").count
    assert_equal 1, CardJob.workflow_runs.for(@card, "bar").count
    assert_equal 0, CardJob.workflow_runs.for(@card).count
    assert_equal "cards/#{@card.id}:foo", CardJob.workflow_runs.for(@card, "foo").sole.key
  end

  test "identified_by narrows the key to the named arguments" do
    IdentifiedCardJob.perform_later(@card, "foo")
    IdentifiedCardJob.perform_later(@card, "bar", style: "x")
    IdentifiedCardJob.perform_later(@other_card, "foo")

    assert_equal ["cards/#{@card.id}"], IdentifiedCardJob.workflow_runs.for(@card).pluck(:key).uniq
    assert_equal 2, IdentifiedCardJob.workflow_runs.for(@card).count
    assert_equal 2, IdentifiedCardJob.workflow_runs.for(@card, "anything", style: "y").count
    assert_equal 1, IdentifiedCardJob.workflow_runs.for(@other_card).count
  end

  test "identified_by rejects a name that is not a perform parameter" do
    error = assert_raises(ArgumentError) do
      Class.new(BaseJob) do
        def perform(card, style:)
          super
        end

        identified_by :card, :kind
      end
    end
    assert_equal "identified_by: unknown perform parameter :kind (perform(card, style:) has card, style)", error.message

    error = assert_raises(ArgumentError) { LateCheckedJob.perform_later(@card) }
    assert_equal "identified_by: unknown perform parameter :kind (perform(card) has card)", error.message
    assert_equal 0, Run.count
  end

  test "identified_by takes a block called with the perform arguments" do
    ExportJob.perform_later(@card)
    ExportJob.perform_later(@card, format: "pdf")
    FixedKeyJob.perform_later

    assert_equal ["cards/#{@card.id}:csv:export", "cards/#{@card.id}:pdf:export"], ExportJob.workflow_runs.pluck(:key).sort
    assert_equal "x", FixedKeyJob.workflow_runs.sole.key
    assert_equal 1, ExportJob.workflow_runs.for(@card).count
    assert_equal 1, ExportJob.workflow_runs.for(@card, format: "pdf").count
    assert_equal 0, ExportJob.workflow_runs.for(@other_card).count
  end

  test "identified_by block does not run on the job" do
    assert_raises(NameError) { SelfReferencingJob.perform_later(@card) }
    assert_raises(NameError) { SelfReferencingJob.workflow_runs.for(@card) }
    assert_equal 0, Run.count
  end

  test "keyword arguments join the default key sorted by name" do
    CardJob.perform_later(@card, style: "b", size: 2)

    assert_equal "cards/#{@card.id}:size=2:style=b", Run.sole.key
    assert_equal 1, CardJob.workflow_runs.for(@card, size: 2, style: "b").count
    assert_equal 0, CardJob.workflow_runs.for(@card, style: "b").count
  end

  test "identified_by resolves a keyword argument by name" do
    StyleJob.perform_later(@card, style: "b")

    assert_equal "b", Run.sole.key
    assert_equal 1, StyleJob.workflow_runs.for(@other_card, style: "b").count
    assert_equal 0, StyleJob.workflow_runs.for(@card, style: "c").count
  end

  test "for(workflow_key:) matches the key verbatim" do
    FixedKeyJob.perform_later
    CardJob.perform_later(@card)

    assert_equal 1, FixedKeyJob.workflow_runs.for(workflow_key: "x").count
    assert_equal 0, CardJob.workflow_runs.for(workflow_key: "x").count
  end

  test "set(workflow_key:) is the key verbatim, over any derivation" do
    IdentifiedCardJob.set(workflow_key: "card-42-v2", queue: "low").perform_later(@card)
    IdentifiedCardJob.perform_later(@card)

    assert_equal ["cards/#{@card.id}", "card-42-v2"], IdentifiedCardJob.workflow_runs.pluck(:key)
    assert_equal "low", queue_adapter.enqueued_jobs.first["queue_name"]
    assert_equal 1, IdentifiedCardJob.workflow_runs.for(@card).count
    assert_not queue_adapter.enqueued_jobs.first.key?("durable_workflow_key")
  end

  test "set(workflow_key:) reaches perform_now and a bulk-enqueued job" do
    CardJob.set(workflow_key: "now").perform_now(@card)
    assert_equal "now", Run.sole.key

    ActiveJob.perform_all_later([CardJob.new(@card).set(workflow_key: "bulk")])
    assert_equal 1, Run.count
    assert_equal "bulk", queue_adapter.enqueued_jobs.sole["durable_workflow_key"]

    perform_enqueued_jobs
    assert_equal %w[bulk now], Run.order(:key).pluck(:key)
    assert_equal "completed", Run.find_by!(key: "bulk").status
  end

  test "status scopes group the statuses" do
    statuses = %w[enqueued running waiting awaiting completed failed halted discarded cancelled]
    statuses.each { |status| create_run(status:) }

    assert_equal %w[enqueued running waiting awaiting], Run.live.newest_first.pluck(:status).reverse
    assert_equal %w[failed halted], Run.attention.order(:id).pluck(:status)
    assert_equal %w[completed discarded cancelled], Run.terminal.order(:id).pluck(:status)
    statuses.each { |status| assert_equal [status], Run.public_send(status).pluck(:status) }

    assert Run.failed.sole.attention?
    assert_not Run.failed.sole.live?
    assert_not Run.completed.sole.attention?
  end

  test "at_step and stuck_for find the runs that need a look" do
    travel_to Time.current do
      create_run(status: "running", current_step: "moderate", last_heartbeat_at: 2.hours.ago)
      create_run(status: "running", current_step: "moderate", last_heartbeat_at: 1.minute.ago)
      create_run(status: "enqueued", current_step: "generate", transitioned_at: 2.hours.ago)
      create_run(status: "completed", current_step: nil, transitioned_at: 2.hours.ago)

      assert_equal 2, Run.at_step(:moderate).count
      assert_equal %w[running enqueued], Run.stuck_for(1.hour).order(:id).pluck(:status)
      assert_equal 1, Run.at_step(:moderate).stuck_for(1.hour).count
      assert_equal 0, Run.stuck_for(3.hours).count
    end
  end

  test "newest_first orders by creation" do
    older = create_run(status: "completed")
    newer = create_run(status: "completed")

    assert_equal [newer.id, older.id], Run.newest_first.pluck(:id)
  end

  test "for without a job class raises" do
    error = assert_raises(ArgumentError) { Run.for(@card) }
    assert_match(/workflow_runs/, error.message)
  end

  private

  def create_run(status:, **)
    Run.create!(
      {
        job_class: "ActiveJob::QueryingTest::CardJob",
        key: "cards/#{@card.id}",
        active_job_id: SecureRandom.uuid,
        arguments: [],
        status:,
        transitioned_at: Time.current,
        **
      }
    )
  end
end
