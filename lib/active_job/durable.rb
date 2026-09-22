# frozen_string_literal: true

require "digest/sha2"
require "active_job"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/numeric/time"
require "active_job/continuable"

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
    include ActiveJob::Continuable

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

    ON_CONFLICT = %i[skip reject replace].freeze

    included do
      class_attribute :durable_identity, instance_writer: false
      class_attribute :durable_uniqueness, instance_writer: false
      class_attribute :durable_on_conflict, instance_writer: false, default: :skip
      class_attribute :durable_halt_errors, instance_writer: false, default: []

      define_callbacks :step, skip_after_callbacks_if_terminated: true

      # Add our hook before Continuable's `around_perform :continue`,
      # so we can wrap it
      around_perform :durable_perform, prepend: true

      after_discard { |_job, error| @durable_discarded_error = error }
      rescue_from(Halt) { |error| durable_halt!(error) }
      rescue_from(Cancelled) { durable_step_finished!("cancelled") }
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
      def identified_by(*names, &block)
        durable_check_identity!(:identified_by, names) if !block && method_defined?(:perform, false)
        self.durable_identity = block || names
      end

      # Specicy the run uniqueness components in the same forms as `identified_by`.
      # Uniqueness is only enforced for runs that hasn't been terminated:  either _live_ runs
      # (with "enqueued", "running", "waiting", "awaiting" status) or _paused_ runs ("failed" or "halted").
      # The `on_conflict:` option defines what to do if the mathing run exists:
      #
      #   unique_by :import                         # :skip — enqueue nothing, `perform_later` returns false
      #   unique_by :payout, on_conflict: :reject   # raise `RunAlreadyExists`
      #   unique_by :license, on_conflict: :replace # cancel that run and start this one
      #
      def unique_by(*names, on_conflict: :skip, &block)
        unless ON_CONFLICT.include?(on_conflict)
          raise ArgumentError, "unique_by: on_conflict must be one of #{ON_CONFLICT.map(&:inspect).join(", ")}, got #{on_conflict.inspect}"
        end

        durable_check_identity!(:unique_by, names) if !block && method_defined?(:perform, false)
        self.durable_uniqueness = block || names
        self.durable_on_conflict = on_conflict
      end

      # Errors that could be resolved by a human (or alike), so the run
      # could be restarted from the current step/cursor.
      def halt_on(*errors)
        self.durable_halt_errors += errors
        rescue_from(*errors) { |error| durable_halt!(error) }
      end

      # Callbacks around every step that runs (a step skipped on resume runs none),
      # with the semantics of `before_perform` and friends; the step is `current_step`.
      # `after_step` runs only when the step completes.
      def before_step(*filters, &blk) = set_callback(:step, :before, *filters, &blk)

      def after_step(*filters, &blk) = set_callback(:step, :after, *filters, &blk)

      def around_step(*filters, &blk) = set_callback(:step, :around, *filters, &blk)

      # This class's runs, newest first. `for(*args, **kwargs)` on the relation
      # finds the runs `perform_later(*args, **kwargs)` would have created;
      # `for(workflow_key: "...")` matches a key verbatim.
      def workflow_runs = Run.where(job_class: name).newest_first

      # The key `perform_later(*args, **kwargs)` builds.
      def durable_key_for(...) = new(...).send(:durable_key) # :nodoc:

      def durable_check_identity!(macro, names) # :nodoc:
        parameters = instance_method(:perform).parameters
        known = parameters.filter_map { |type, name| name if %i[req opt key keyreq].include?(type) }
        unknown = names.find { |name| !known.include?(name) } or return

        signature = parameters.map do |type, name|
          case type
          when :req then name.to_s
          when :opt then "#{name} = ..."
          when :rest then "*#{name}"
          when :keyreq then "#{name}:"
          when :key then "#{name}: ..."
          when :keyrest then "**#{name}"
          when :block then "&#{name}"
          end
        end.join(", ")
        raise ArgumentError, "#{macro}: unknown perform parameter #{unknown.inspect} (perform(#{signature}) has #{known.join(", ")})"
      end
    end

    # Creates the run before the job is handed to the adapter, so that the row is
    # part of the caller's transaction when enqueuing is deferred to after commit.
    # A retry or resume (same `job_id`) finds the row and only updates its status.
    def enqueue(options = {})
      @durable_workflow_key = options[:workflow_key]&.to_s
      durable_run_enqueued!
      return false if @durable_conflict # `on_conflict: :skip`: nothing to enqueue

      super
    end

    # Supports `set(workflow_key: "...")`to provide an explicit workflow (not run) identifier.
    def set(options = {}) # :nodoc:
      @durable_workflow_key = options[:workflow_key]&.to_s
      super
    end

    # Continuable's `step`, plus a timer (`wait:` or
    # `wait_until:`):
    #
    #   step :remind, wait_until: license.expires_at - 2.weeks
    #   step :revoke, wait: 2.weeks
    #
    def step(step_name, start: nil, isolated: false, wait: nil, wait_until: nil, &block)
      block ||= durable_step_method(step_name)
      raise ArgumentError, "Step '#{step_name}' takes wait: or wait_until:, not both" if wait && wait_until

      super(step_name, start:, isolated:) do |step|
        durable_wait!(step, wait, wait_until) if wait || wait_until || @durable_await
        @current_step = step
        durable_step_started!(step, isolated)
        run_callbacks(:step) { block.call(step) }
        durable_step_completed!(step)
      ensure
        @current_step = nil
      end
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
      handler = block || durable_step_method(name)
      @durable_await = name.to_s
      step(name, wait:, wait_until:) { handler.call(@durable_await_value) }
    ensure
      @durable_await = nil
    end

    # The `ActiveJob::Continuation::Step` that is running, `nil` between steps.
    # (`Run#current_step` is the step's name.)
    attr_reader :current_step

    # Stops the run from inside a step: status `halted` with `halt_reason`, the
    # step row keeps its cursor, and the job's serialized form is parked on the run.
    def halt!(reason = nil)
      raise ArgumentError, "halt! must be called inside a step" unless current_step

      raise Halt.new(reason)
    end

    def checkpoint! # :nodoc:
      durable_checkpoint!
      super
    end

    # The run must be the only source of truth, so drop the base continuation
    # parameters from the payload. A workflow key travels only until the row
    # exists (`perform_all_later` creates it at the first execution).
    def serialize # :nodoc:
      payload = super.except("continuation", "attributes", "resumptions").merge("durable_run_id" => @durable_run&.id)
      payload["durable_workflow_key"] = @durable_workflow_key if @durable_workflow_key && !@durable_run
      payload
    end

    def deserialize(job_data) # :nodoc:
      super
      @durable_run_id = job_data["durable_run_id"]
      @durable_workflow_key = job_data["durable_workflow_key"]
    end

    # A run is `discarded` when Active Job swallowed the error and `failed` when the
    # error is raised to the backend; a retried job is `enqueued` again by `enqueue`.
    def perform_now # :nodoc:
      @durable_discarded_error = nil
      result = super
      durable_run_discarded!(@durable_discarded_error) if @durable_discarded_error
      result
    rescue Exception => err # rubocop:disable Lint/RescueException
      durable_run_failed!(err) unless @durable_conflict
      raise
    end

    private

    def deserialize_arguments_if_needed
      super
      durable_restore_from_run! if @durable_run_id
    end

    def durable_restore_from_run!
      run_id, @durable_run_id = @durable_run_id, nil
      run = Run.find_by(id: run_id, active_job_id: job_id)
      raise RunNotFoundError, "Run #{run_id} for #{self.class.name} (Job ID: #{job_id}) was not found" unless run

      @durable_run = run
      @durable_state_written = run.serialized_state
      @durable_deadline, @durable_deadline_step = run.wake_at, run.current_step
      self.resumptions = run.resumptions
      self.continuation = Continuation.new(self, durable_serialized_progress(run))
      # A run that starts from its parked job was re-enqueued by `resume!` (or by
      # the backend), not by Continuation, so it is not one of its resumptions;
      # `continue` still adds one when the run has progress, so start one below.
      self.resumptions -= 1 if run.parked_job.present? && continuation.started?
      if run.state.present? && respond_to?(:deserialize_attribute_values, true)
        deserialize_attribute_values(run.serialized_state)
      end
    end

    def durable_serialized_progress(run)
      progress = {"completed" => Array(run.completed_steps)}
      if run.current_step && (cursor, _ = Step.where(run_id: run.id, name: run.current_step).order(attempt: :desc).pick(:cursor, :attempt))
        progress["current"] = [run.current_step, durable_cursor_for_continuation(cursor)]
      end
      progress
    end

    def durable_cursor_for_continuation(serialized_cursor)
      if Continuation.private_method_defined?(:serialized_current)
        serialized_cursor # Rails 8.2+
      else
        Arguments.deserialize([serialized_cursor]).first # Rails <8.2
      end
    end

    def resume_job(exception) # :nodoc:
      error = exception.is_a?(Hash) ? exception[:exception] : exception
      raise error if durable_halt?(error)

      @durable_resumed = true
      return if @durable_parked # the row is written; the clock or a signal re-enqueues

      if error.is_a?(Continuation::Interrupt)
        durable_step_finished!("interrupted") # Rails 8.2+
      else
        durable_step_finished!("failed", error:) # Rails <8.2
      end
      durable_write_running!(state: durable_state, resumptions:, last_heartbeat_at: Time.current)
      super
    end

    # Wraps Continuable's `continue`.
    def durable_perform
      return if durable_run&.terminal? # cancelled while the job was in the queue

      @durable_step = nil
      @durable_resumed = false
      @durable_parked = false
      durable_run_started! or return # a bulk-enqueued job whose key another run holds
      yield
      durable_run_completed! unless @durable_resumed
    rescue Exception => error # rubocop:disable Lint/RescueException
      durable_step_finished!("failed", error:) unless durable_halt?(error) || error.is_a?(Cancelled)
      raise
    end

    def durable_halt?(error) = error.is_a?(Halt) || durable_halt_errors.any? { |klass| error.is_a?(klass) }

    def durable_halt!(error)
      halt = error.is_a?(Halt)
      durable_step_finished!("halted", error: (error unless halt))
      durable_write_run(
        if_status: "running",
        status: "halted",
        state: durable_state,
        resumptions:,
        parked_job: serialize,
        halt_reason: (error.reason&.to_s if halt),
        error_class: (error.class.name unless halt),
        error_message: (error.message unless halt),
        transitioned_at: Time.current
      )
    end

    def durable_run = @durable_run ||= Run.find_by(active_job_id: job_id)

    # Last write wins, within `if_status:`. False, and nothing written, when the
    # row was not created because another run holds the key (`on_conflict: :skip`).
    def durable_upsert_run!(if_status: nil, **attributes)
      return durable_write_run(if_status:, **attributes) if durable_run

      attributes = {
        job_class: self.class.name,
        key: durable_key,
        active_key: (durable_active_key if durable_uniqueness),
        arguments: serialize_arguments_if_needed(arguments),
        state: durable_state,
        transitioned_at: Time.current
      }.merge(attributes)
      run = durable_create_run(attributes) or return false
      @durable_run = run

      if run.previously_new_record?
        @durable_state_written = attributes[:state]
        true
      else
        durable_write_run(if_status:, **attributes)
      end
    end

    # Inserts the row; finds it instead when this job is already recorded (two
    # executions of one job). With `unique_by`, a run holding the same
    # `active_key` decides first, by `on_conflict`; the unique index settles a
    # race between two first enqueues, and the loser looks again, once.
    def durable_create_run(attributes, retried: false)
      Run.transaction(requires_new: true) do
        if durable_uniqueness && (live = durable_live_run(attributes[:active_key]))
          durable_resolve_conflict!(live) or next
        end
        Run.create!(active_job_id: job_id, **attributes)
      end
    rescue ActiveRecord::RecordNotUnique
      Run.find_by(active_job_id: job_id) || (retried ? raise : durable_create_run(attributes, retried: true))
    end

    def durable_live_run(active_key) = Run.find_by(job_class: self.class.name, active_key:)

    # True when this run may be inserted.
    def durable_resolve_conflict!(live)
      case durable_on_conflict
      when :skip
        @durable_conflict = live
        false
      when :reject
        @durable_conflict = live
        raise RunAlreadyExists.new(live)
      when :replace
        begin
          live.cancel!
        rescue NotCancellable
          # ended meanwhile: its key is free
        end
        true
      end
    end

    # A re-enqueue of a cancelled run leaves the row alone; the queued job
    # then performs nothing.
    def durable_run_enqueued!
      attributes = {status: "enqueued", finished_at: nil, transitioned_at: Time.current}
      attributes[:state] = durable_state unless @durable_run_id # a job built from its payload has not read the row yet
      durable_upsert_run!(if_status: Run::CANCELLABLE_STATUSES, **attributes)
    end

    def durable_run_started!
      now = Time.current
      written = durable_upsert_run!(
        if_status: Run::CANCELLABLE_STATUSES,
        status: "running",
        started_at: durable_run&.started_at || now,
        last_heartbeat_at: now,
        resumptions: durable_resumptions,
        parked_job: nil,
        transitioned_at: now
      )
      return false if @durable_conflict

      written or raise Cancelled, "Run #{durable_run.id} was cancelled"
    end

    def durable_run_completed!
      now = Time.current
      durable_write_running!(
        status: "completed",
        current_step: nil,
        active_key: nil,
        state: durable_state,
        resumptions:,
        finished_at: now,
        transitioned_at: now
      )
    end

    def durable_run_failed!(error)
      now = Time.current
      durable_upsert_run!(
        if_status: Run::CANCELLABLE_STATUSES,
        status: "failed",
        state: durable_state,
        resumptions:,
        parked_job: serialize,
        error_class: error.class.name,
        error_message: error.message,
        finished_at: now,
        transitioned_at: now
      )
    end

    def durable_run_discarded!(error)
      now = Time.current
      durable_upsert_run!(
        if_status: Run::CANCELLABLE_STATUSES,
        status: "discarded",
        active_key: nil,
        error_class: error.class.name,
        error_message: error.message,
        finished_at: now,
        transitioned_at: now
      )
    end

    # One UPDATE, no callbacks or validations; the loaded row is not refreshed.
    # `if_status:` guards the statement with the row's current status: false,
    # and nothing written, when the run left that status meanwhile.
    def durable_write_run(if_status: nil, **attributes)
      run = durable_run or return true

      @durable_state_written = attributes[:state] if attributes.key?(:state)
      scope = Run.where(id: run.id)
      scope = scope.where(status: if_status) if if_status
      scope.update_all(**attributes, updated_at: Time.current).positive?
    end

    # The only way a `running` run changes status from outside is `Run#cancel!`.
    def durable_write_running!(**attributes)
      durable_write_run(if_status: "running", **attributes) or raise Cancelled, "Run #{durable_run.id} was cancelled"
    end

    # The guarded run write comes first, so a cancelled run gets no row for a
    # step that never started. A signal for this step is consumed here, under
    # the row lock `Run#wake_up` takes, and lands in the step row's cursor.
    def durable_step_started!(step, isolated)
      run = durable_run or return
      name = step.name.to_s

      @durable_step_await = (@durable_await == name)
      Run.transaction do
        signals = durable_pending_signals(lock: true)
        attributes = {current_step: name, wake_at: nil}
        if signals.key?(name)
          attributes[:pending_signals] = signals.except(name)
          @durable_await_value = signals[name] if @durable_step_await
        end
        durable_write_running!(**attributes)

        @durable_step = run.steps.create(
          name:,
          position: continuation.instrumentation[:completed_steps].size + 1,
          attempt: Step.where(run_id: run.id, name:).maximum(:attempt).to_i + 1,
          status: "started",
          cursor: durable_serialize_cursor(durable_step_cursor(step)),
          isolated:,
          started_at: Time.current
        )
      end
      @durable_deadline = nil
    end

    # The guarded run write comes first: a step whose completion the cancelled
    # run did not record is closed as `cancelled`, like one stopped mid-way.
    def durable_step_completed!(step)
      step_row = @durable_step or return
      now = Time.current
      completed_steps = continuation.instrumentation[:completed_steps].map(&:to_s) << step.name.to_s
      durable_write_running!(completed_steps:, current_step: nil, state: durable_state, last_heartbeat_at: now)

      @durable_step = nil
      step_row.update_columns(status: "completed", cursor: durable_serialize_cursor(durable_step_cursor(step)), finished_at: now)
    end

    def durable_step_finished!(status, error: nil)
      step_row = @durable_step or return
      @durable_step = nil
      current = continuation.instrumentation[:current_step]

      step_row.update_columns(
        status:,
        cursor: current ? durable_serialize_cursor(durable_step_cursor(current)) : step_row.cursor,
        error_class: error&.class&.name,
        error_message: error&.message,
        finished_at: Time.current
      )
    end

    # Parks the run when the step's signal has not arrived and its deadline has
    # not passed: the row is written under the row lock (so a signal sent
    # meanwhile finds it `awaiting` and wakes it), then the job is interrupted
    # and `resume_job` leaves it to the clock or to `Run#wake_up`. A resumed
    # step does not wait again, except an `await` whose handler halted.
    def durable_wait!(step, wait, wait_until)
      durable_run or return
      name = step.name.to_s
      await = @durable_await == name
      resumed = step.resumed? && !(await && durable_halted?(name))
      @durable_await_value = (step.cursor if resumed) if await
      return if resumed

      status = Run.transaction do
        next if durable_pending_signals(lock: true).key?(name)

        deadline = durable_deadline(name, wait, wait_until)
        next if deadline && deadline <= Time.current

        parked = await ? "awaiting" : "waiting"
        durable_write_running!(
          status: parked, current_step: name, wake_at: deadline, state: durable_state, resumptions:,
          parked_job: serialize, transitioned_at: Time.current
        )
        @durable_deadline, @durable_deadline_step = deadline, name
        parked
      end
      return unless status

      @durable_parked = true
      interrupt!(reason: status.to_sym)
    end

    # A `wait_until:` is read again at every wake; a `wait:` counts from the
    # first time the line is reached and is then kept on the row.
    def durable_deadline(name, wait, wait_until)
      if wait_until
        durable_timer_value(wait_until)
      elsif wait
        (@durable_deadline if @durable_deadline_step == name) || Time.current + durable_timer_value(wait)
      end
    end

    def durable_timer_value(value) = value.respond_to?(:call) ? value.call : value

    def durable_halted?(name) = Step.where(run_id: durable_run.id, name:).order(attempt: :desc).pick(:status) == "halted"

    def durable_pending_signals(lock: false)
      scope = Run.where(id: durable_run.id)
      scope = scope.lock if lock
      scope.pick(:pending_signals) || {}
    end

    # An `await` step's cursor is the signal value, whatever the resumed step carries.
    def durable_step_cursor(step) = @durable_step_await ? @durable_await_value : step.cursor

    # The cursor is committed first, so a cancelled step keeps it; the guarded
    # heartbeat write is what detects the cancel.
    def durable_checkpoint!
      return unless durable_run

      if @durable_step && (current = continuation.instrumentation[:current_step])
        @durable_step.update_columns(cursor: durable_serialize_cursor(durable_step_cursor(current)))
      end

      attributes = {last_heartbeat_at: Time.current}
      state = durable_state
      attributes[:state] = state unless state == @durable_state_written
      durable_write_running!(**attributes)
    end

    # The attribute values as `ActiveJob::Attributes#serialize` puts them under
    # `"attributes"`. Rails 8.1 has no Attributes.
    def durable_state = respond_to?(:serialize_attribute_values, true) ? serialize_attribute_values : {}

    def durable_serialize_cursor(cursor) = Arguments.serialize([cursor]).first

    def durable_resumptions = continuation.started? ? resumptions + 1 : resumptions

    # The run's identity inside the class: `set(workflow_key:)` verbatim, else the
    # `identified_by` components (or every argument) rendered and joined with ":".
    def durable_key
      return @durable_workflow_key if @durable_workflow_key

      if durable_identity || !durable_uniqueness
        durable_render_key(durable_identity, :identified_by)
      else
        durable_render_key(durable_uniqueness, :unique_by)
      end
    end

    # The identity one run holds at a time: `set(workflow_key:)` verbatim, else
    # the `unique_by` components.
    def durable_active_key = @durable_workflow_key || durable_render_key(durable_uniqueness, :unique_by)

    def durable_render_key(identity, macro)
      components = arguments_serialized? ? [] : durable_identity_components(identity, macro)
      if components.empty?
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(serialize_arguments_if_needed(arguments)))
      else
        components.map { |component| durable_key_component(component) }.join(":")
      end
    end

    def durable_identity_components(identity, macro)
      positional, keywords = durable_split_arguments

      if identity.is_a?(Proc)
        value = identity.call(*positional, **keywords)
        value.is_a?(Array) ? value : [value]
      elsif identity.present?
        self.class.durable_check_identity!(macro, identity)
        identity.map { |name| durable_named_component(name, positional, keywords) }
      else
        positional + keywords.sort_by { |name, _| name.to_s }.map { |name, value| "#{name}=#{durable_key_component(value)}" }
      end
    end

    def durable_named_component(name, positional, keywords)
      parameters = self.class.instance_method(:perform).parameters
      positional_names = parameters.filter_map { |type, parameter| parameter if type == :req || type == :opt }

      if (index = positional_names.index(name))
        positional[index]
      else
        keywords[name]
      end
    end

    # Active Job stores keyword arguments as a trailing ruby2_keywords hash.
    def durable_split_arguments
      positional = arguments.dup
      keywords = (positional.last.is_a?(Hash) && Hash.ruby2_keywords_hash?(positional.last)) ? positional.pop : {}
      [positional, keywords.transform_keys(&:to_sym)]
    end

    def durable_key_component(value)
      case value
      when GlobalID::Identification then "#{durable_collection_name(value)}/#{value.id}"
      when Symbol, String, Integer, Float, true, false then value.to_s
      when nil then ""
      else Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(Arguments.serialize([value])))[0, 16]
      end
    end

    def durable_collection_name(record)
      if record.respond_to?(:model_name)
        record.model_name.collection
      else
        ActiveModel::Name.new(record.class).collection
      end
    end

    def durable_step_method(step_name)
      step_method = method(step_name)

      raise ArgumentError, "Step method '#{step_name}' must accept 0 or 1 arguments" if step_method.arity > 1

      if step_method.parameters.any? { |type, _name| type == :key || type == :keyreq }
        raise ArgumentError, "Step method '#{step_name}' must not accept keyword arguments"
      end

      (step_method.arity == 0) ? ->(_step) { step_method.call } : step_method
    end
  end
end
