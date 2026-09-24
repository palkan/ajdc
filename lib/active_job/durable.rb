# frozen_string_literal: true

require "digest/sha2"
require "active_job"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/numeric/time"
require "active_job/continuable/callbacks"

module ActiveJob
  # = Active Job Durable
  #
  # A Continuable job whose run is also a record. Include it instead of
  # `ActiveJob::Continuable`:
  #
  #   class ProcessImportJob < ApplicationJob
  #     include ActiveJob::Durable
  #
  #     def perform(import)
  #       step :validate
  #       step :process, isolated: true
  #     end
  #   end
  #
  # Steps, cursors and attributes behave exactly as in `ActiveJob::Continuable`,
  # but the run row is the single source of truth: the payload carries
  # `"durable_run_id"` instead of `"continuation"`, `"attributes"` and
  # `"resumptions"`, and every execution rebuilds the continuation, the attribute
  # values and the resumption count from `active_job_durable_runs` and the
  # current attempt in `active_job_durable_steps`. The rows are written before
  # the job is re-enqueued, in every path.
  module Durable
    extend ActiveSupport::Concern
    include ActiveJob::Continuable::Callbacks

    autoload :ArgsMapper, "active_job/durable/args_mapper"
    autoload :Config, "active_job/durable/config"
    autoload :Continuation, "active_job/durable/continuation"
    autoload :Execution, "active_job/durable/execution"
    autoload :Record, "active_job/durable/record"
    autoload :Run, "active_job/durable/run"
    autoload :Step, "active_job/durable/step"
    autoload :WakeJob, "active_job/durable/wake_job"

    mattr_accessor :connects_to, instance_accessor: false

    # Wakes every `waiting` or `awaiting` run whose `wake_at` has passed, once each, and
    # returns how many. `WakeJob` calls it on schedule; tests call it inside `travel_to`.
    def self.wake_up_due = Run.wake_due

    # Raised inside `perform_now` when the payload references a run row that does
    # not exist (or belongs to another job), so `retry_on`, `discard_on` and
    # `rescue_from` handlers can see it.
    class RunNotFoundError < StandardError; end

    # Raised by `Run#resume!` when the run is not `halted` or `failed`, or when
    # another caller resumed it first.
    class NotResumable < StandardError; end

    # Raised by `Run#cancel!` when the run is terminal, or when another caller
    # ended it first.
    class NotCancellable < StandardError; end

    # Raised by `Run#wake_up` when the run is not `waiting`, or when the clock
    # or another caller woke it first.
    class NotWaiting < StandardError; end

    # Raised by `Run#wake_up(name, value)` when the run is not live: a signal
    # for a run that ended, or that needs attention first, has no one to consume it.
    class NotLive < StandardError; end

    # Raised by `unique_by ..., on_conflict: :reject` when a run with the same
    # `active_key` is live or needs attention; `run` is that run.
    class RunAlreadyExists < StandardError
      attr_reader :run

      def initialize(run)
        @run = run
        super("Run #{run.id} for #{run.job_class} (#{run.active_key}) is #{run.status}")
      end
    end

    # Raised by `halt!`
    class Halt < Exception # rubocop:disable Lint/InheritException
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super(reason ? "Halted (#{reason})" : "Halted")
      end
    end

    # Raised at a checkpoint or a step boundary when `Run#cancel!` ended the run
    # meanwhile: the job stops, the open step row is `cancelled` and the job
    # handles the error itself, so nothing reaches the backend.
    class Cancelled < Exception # rubocop:disable Lint/InheritException
    end

    included do
      self.continuation_class = Continuation

      # Ensure run checkpoints are written before any other callback
      around_step(prepend: true) { |_job, block| durable_job.step(&block) }

      # Add our hook before Continuable's `around_perform :continue`,
      # so we can wrap it
      around_perform(prepend: true) { |_job, block| durable_job.perform(&block) }

      after_discard { |_job, error| durable_job.record_discard(error) }
      rescue_from(Halt) { |error| durable_job.halted!(error) }
    end

    module ClassMethods
      # Names the components of a run's `key`: `perform` parameters (positional by
      # name, keywords by key), or a block called with the `perform` arguments
      # whose return value is the key (rendered like any component, or joined
      # with ":" when it is an array):
      #
      #   identified_by :card                 # key "cards/42", whatever the other arguments
      #   identified_by :card, :style         # key "cards/42:plain" for perform(card, style: "plain")
      #   identified_by { |card, **| [card.account, :export] }
      #
      # A name that is not a `perform` parameter raises `ArgumentError`.
      #
      # Without a declaration every argument is a component: positional in order,
      # then keywords sorted by name as `name=value`.
      def identified_by(...) = durable_config.identified_by(...)

      # Specicy the run uniqueness components in the same forms as `identified_by`.
      # Uniqueness is only enforced for runs that hasn't been terminated:  either _live_ runs
      # (with "enqueued", "running", "waiting", "awaiting" status) or _paused_ runs ("failed" or "halted").
      # The `on_conflict:` option defines what to do if the mathing run exists:
      #
      #   unique_by :import                         # :skip — enqueue nothing, `perform_later` returns false
      #   unique_by :payout, on_conflict: :reject   # raise `RunAlreadyExists`
      #   unique_by :license, on_conflict: :replace # cancel that run and start this one
      #
      def unique_by(*names, on_conflict: :skip, &block) = durable_config.unique_by(*names, on_conflict:, &block)

      # Errors that could be resolved by a human (or alike), so the run
      # could be restarted from the current step/cursor.
      def halt_on(*errors)
        durable_config.halt_on(*errors)
        rescue_from(*errors) { |error| durable_job.halted!(error) }
      end

      # This class's runs, newest first. `for(*args, **kwargs)` on the relation
      # finds the runs `perform_later(*args, **kwargs)` would have created;
      # `for(workflow_key: "...")` matches a key verbatim.
      def workflow_runs = Run.where(job_class: name).newest_first

      # Macros write to this class's own copy of its parent's configuration.
      def durable_config # :nodoc:
        @durable_config ||= superclass.respond_to?(:durable_config) ? superclass.durable_config.inherit(self) : Config.new(self)
      end
    end

    # Creates the run before the job is handed to the adapter, so that the row is
    # part of the caller's transaction when enqueuing is deferred to after commit.
    # A retry or resume (same `job_id`) finds the row and only updates its status.
    def enqueue(options = {})
      durable_job.workflow_key = options[:workflow_key]&.to_s
      return false unless durable_job.enqueued! # `on_conflict: :skip`: nothing to enqueue

      super
    end

    # Supports `set(workflow_key: "...")`to provide an explicit workflow (not run) identifier.
    def set(options = {}) # :nodoc:
      durable_job.workflow_key = options[:workflow_key]&.to_s
      super
    end

    # Continuable's `step`, plus a timer (`wait:` or
    # `wait_until:`):
    #
    #   step :remind, wait_until: license.expires_at - 2.weeks
    #   step :revoke, wait: 2.weeks
    #
    def step(step_name, wait: nil, wait_until: nil, **, &block)
      raise ArgumentError, "Step '#{step_name}' takes wait: or wait_until:, not both" if wait && wait_until

      super
    end

    # A step that waits for a signal from outside (`Run#wake_up(name, value)`):
    #
    #   await :confirmation, wait: 10.minutes
    #
    #   def confirmation(signal) = self.confirmed = signal.presence
    #
    # Reaching the line parks the run as `awaiting` until the signal arrives or
    # the deadline (`wait:` or `wait_until:`, none by default) passes; the method
    # named after the signal, or the block, then runs as the step's body with the
    # value, `nil` at the deadline. A signal sent before the line is reached is
    # consumed on the spot. The step row's cursor keeps the value, so a crash in
    # the handler replays it; a `halt!` in the handler awaits again on resume.
    def await(name, wait: nil, wait_until: nil, &block)
      handler = block || step_method_block(name)
      step(name, wait:, wait_until:, await: true) { handler.call(durable_job.await_value) }
    end

    # Stops the run from inside a step: status `halted` with `halt_reason`, the
    # step row keeps its cursor, and the job's serialized form is parked on the run.
    def halt!(reason = nil)
      raise ArgumentError, "halt! must be called inside a step" unless current_step

      raise Halt.new(reason)
    end

    def checkpoint! # :nodoc:
      durable_job.checkpoint!
      super
    end

    def serialize = durable_job.serialize(super) # :nodoc:

    def deserialize(job_data) # :nodoc:
      super
      durable_job.deserialize(job_data)
    end

    def perform_now = durable_job.perform_now { super } # :nodoc:

    private

    def durable_job = @durable_job ||= Execution.new(self)

    def deserialize_arguments_if_needed
      super
      durable_job.restore!
    end

    def resume_job(exception) # :nodoc:
      error = exception.is_a?(Hash) ? exception[:exception] : exception
      super if durable_job.resume!(error)
    end
  end
end
