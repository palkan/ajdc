# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/with"

class ActiveJob::HousekeepingTest < ActiveSupport::TestCase
  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  setup do
    Step.delete_all
    Run.delete_all
  end

  test "keeps terminal runs for 14 days by default" do
    assert_equal 14.days, ActiveJob::Durable.keep_terminal_runs_for
    assert_kind_of ActiveSupport::OrderedOptions, Rails.application.config.active_job_durable
  end

  test "clean_up deletes the terminal runs that ended before the retention period, with their steps" do
    old = %w[completed discarded cancelled].map { |status| create_run(status:, ended_at: 15.days.ago) }
    recent = create_run(status: "completed", ended_at: 13.days.ago)
    kept = %w[failed halted running waiting].map { |status| create_run(status:, ended_at: 30.days.ago) }

    assert_equal 3, ActiveJob::Durable.clean_up

    assert_equal [recent, *kept].map(&:id).sort, Run.ids.sort
    assert_equal [recent, *kept].map(&:id).sort, Step.distinct.pluck(:run_id).sort
    assert_empty Step.where(run_id: old.map(&:id))
  end

  test "clean_up deletes in batches" do
    5.times { create_run(status: "completed", ended_at: 15.days.ago) }

    assert_equal 5, Run.clear_terminal(ended_before: 14.days.ago, batch_size: 2)
    assert_equal 0, Run.count
    assert_equal 0, Step.count
  end

  test "a nil retention period keeps every run" do
    create_run(status: "completed", ended_at: 1.year.ago)

    ActiveJob::Durable.with(keep_terminal_runs_for: nil) do
      assert_equal 0, ActiveJob::Durable.clean_up
    end
    assert_equal 1, Run.count
  end

  test "HousekeepingJob cleans up" do
    create_run(status: "completed", ended_at: 15.days.ago)

    ActiveJob::Durable::HousekeepingJob.perform_now

    assert_equal 0, Run.count
  end

  private

  def create_run(status:, ended_at:)
    run = Run.create!(
      job_class: "SomeJob",
      key: SecureRandom.hex(4),
      active_job_id: SecureRandom.uuid,
      arguments: [],
      status:,
      finished_at: (ended_at if Run::TERMINAL_STATUSES.include?(status)),
      transitioned_at: ended_at
    )
    run.steps.create!(name: "one", position: 1, status: "completed")
    run
  end
end
