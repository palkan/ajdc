# frozen_string_literal: true

require "test_helper"
require "active_job/continuation/test_helper"
require "active_support/core_ext/object/with"

class ActiveJob::DurableStateTest < ActiveSupport::TestCase
  include ActiveJob::Continuation::TestHelper
  include DoNotPerformEnqueuedJobs

  Run = ActiveJob::Durable::Run
  Step = ActiveJob::Durable::Step

  class CardGenerationJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
    include ActiveJob::Durable

    attribute :verdict, :string if rails_version_is("8.2"..)

    def perform(card)
      step :prepare
      step :moderate
      step :generate
    end

    private

    def prepare
    end

    def moderate
      self.verdict = "unsure" if respond_to?(:verdict=)
    end

    def generate
    end
  end

  class IteratingJob < CardGenerationJob
    cattr_accessor :items, default: []

    attribute :note, :string if rails_version_is("8.2"..)

    def perform(objects)
      step :iterate, start: 0 do |step|
        objects[step.cursor..].each do |object|
          items << object
          step.advance!
        end
      end
      step :finish do
        items << "note=#{note}" if respond_to?(:note)
      end
    end
  end

  class MissingRunJob < CardGenerationJob
    cattr_accessor :error

    discard_on(ActiveJob::Durable::RunNotFoundError) { |job, error| job.class.error = error }
  end

  setup do
    Step.delete_all
    Run.delete_all
    IteratingJob.items = []
    @card = Card.create!(title: "Hello")
  end

  test "perform_later records the run before it performs" do
    CardGenerationJob.perform_later(@card)

    run = Run.sole
    assert_equal "ActiveJob::DurableStateTest::CardGenerationJob", run.job_class
    assert_equal "cards/#{@card.id}", run.key
    assert_equal "enqueued", run.status
    assert_equal [], run.completed_steps
    assert_nil run.current_step
    rails_version_is("8.2"..) { assert_equal({"verdict" => nil}, run.state) }
    assert_equal 0, Step.count
  end

  test "performing completes the run, its steps and its state" do
    CardGenerationJob.perform_later(@card)
    perform_enqueued_jobs

    run = Run.sole
    assert_equal "completed", run.status
    assert_equal %w[prepare moderate generate], run.completed_steps
    assert_nil run.current_step
    rails_version_is("8.2"..) { assert_equal({"verdict" => "unsure"}, run.state) }

    steps = Step.where(run_id: run.id).order(:position)
    assert_equal %w[prepare moderate generate], steps.map(&:name)
    assert_equal %w[completed completed completed], steps.map(&:status)
    assert_equal [1, 1, 1], steps.map(&:attempt)
  end

  test "an interrupted step keeps its cursor in the row and resumes from it" do
    objects = %w[a b c d e]
    IteratingJob.perform_later(objects)

    interrupt_job_during_step(IteratingJob, :iterate, cursor: 2) do
      assert_enqueued_jobs(1) { perform_enqueued_jobs }
    end

    run = Run.sole
    assert_equal "enqueued", run.status
    assert_equal "iterate", run.current_step
    interrupted = Step.find_by!(run_id: run.id, name: "iterate", attempt: 1)
    assert_equal "interrupted", interrupted.status
    assert_equal 2, interrupted.cursor

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    assert_equal objects, IteratingJob.items.grep(String).first(5)
    assert_equal "completed", run.reload.status
    assert_equal [1, 2], Step.where(run_id: run.id, name: "iterate").order(:attempt).pluck(:attempt)
    assert_equal "completed", Step.find_by!(run_id: run.id, name: "iterate", attempt: 2).status
  end

  test "the payload carries the run id and no progress" do
    job = CardGenerationJob.perform_later(@card)
    payload = job.serialize

    assert_equal Run.sole.id, payload["durable_run_id"]
    assert_not payload.key?("continuation")
    rails_version_is("8.2"..) { assert_not payload.key?("attributes") }
  end

  test "the row is the source of truth on resume" do
    IteratingJob.perform_later(%w[a b c d e])

    interrupt_job_during_step(IteratingJob, :iterate, cursor: 2) { perform_enqueued_jobs }

    run = Run.sole
    Step.find_by!(run_id: run.id, name: "iterate", attempt: 1).update_columns(cursor: 4)
    rails_version_is("8.2"..) { run.update!(state: {"note" => "from-row"}) }

    perform_enqueued_jobs

    expected = %w[a b e]
    expected << "note=from-row" if rails_version_is("8.2"..)
    assert_equal expected, IteratingJob.items
    assert_equal "completed", run.reload.status
  end

  test "a missing run row is an error the job's handlers see" do
    MissingRunJob.error = nil
    MissingRunJob.perform_later(@card)
    Run.delete_all

    assert_enqueued_jobs(0) { perform_enqueued_jobs }

    assert_kind_of ActiveJob::Durable::RunNotFoundError, MissingRunJob.error
    assert_equal "discarded", Run.sole.status
  end

  test "perform_now creates the run at its first execution" do
    CardGenerationJob.perform_now(@card)

    assert_equal "completed", Run.sole.status
    assert_equal "cards/#{@card.id}", Run.sole.key
  end

  test "perform_all_later creates the run at its first execution" do
    ActiveJob.perform_all_later(CardGenerationJob.new(@card))
    assert_equal 0, Run.count
    assert_nil queue_adapter.enqueued_jobs.first["durable_run_id"]

    perform_enqueued_jobs

    assert_equal "completed", Run.sole.status
  end
end
