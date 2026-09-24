# frozen_string_literal: true

module ActiveJob
  module Durable
    # Mediates between a durable job and its run: reads the job's configuration
    # and state, and keeps the run and step rows in sync with its execution.
    # One per job instance.
    class Execution # :nodoc:
      attr_accessor :workflow_key

      # The value an `await` step's handler receives.
      attr_reader :await_value

      def initialize(job)
        @job = job
      end

      def run_id = @run&.id

      # The run must be the only source of truth, so drop the base continuation
      # parameters from the payload.
      def serialize(payload)
        payload = payload.except("continuation", "attributes", "resumptions").merge("durable_run_id" => run_id)
        # A workflow key makes sense only when the row exists
        payload["durable_workflow_key"] = workflow_key if workflow_key && !@run
        payload
      end

      def deserialize(job_data)
        @serialized_run_id = job_data["durable_run_id"]
        self.workflow_key = job_data["durable_workflow_key"]
      end

      # Rebuilds the continuation, the resumption count and the attribute values
      # from the run the payload references.
      def restore!
        run_id, @serialized_run_id = @serialized_run_id, nil
        return unless run_id

        run = Run.find_by(id: run_id, active_job_id: job.job_id)
        raise RunNotFoundError, "Run #{run_id} for #{job.class.name} (Job ID: #{job.job_id}) was not found" unless run

        @run = run
        @state_written = run.serialized_state
        @deadline, @deadline_step = run.wake_at, run.current_step
        job.resumptions = run.resumptions
        job.continuation = job.continuation_class.new(job, serialized_progress(run))
        # A run that starts from its parked job was re-enqueued by `resume!` (or by
        # the backend), not by Continuation, so it is not one of its resumptions;
        # `continue` still adds one when the run has progress, so we need to adjust
        job.resumptions -= 1 if run.parked_job.present? && job.continuation.started?
        if run.state.present? && job.respond_to?(:deserialize_attribute_values, true)
          job.send(:deserialize_attribute_values, run.serialized_state)
        end
      end

      def enqueued!
        attributes = {status: "enqueued", finished_at: nil, transitioned_at: Time.current}
        attributes[:state] = state unless @serialized_run_id # a job built from its payload has not read the row yet
        upsert_run!(if_status: Run::CANCELLABLE_STATUSES, **attributes)
        !@conflict
      end

      # Wraps `perform_now`: a run is `discarded` when Active Job swallowed the
      # error and `failed` when the error is raised to the backend; a retried job
      # is `enqueued` again by `enqueue`.
      def perform_now
        @discarded_error = nil
        result = yield
        discarded!(@discarded_error) if @discarded_error
        result
      rescue Exception => error # rubocop:disable Lint/RescueException
        failed!(error) unless @conflict
        raise
      end

      # Remembers the error Active Job discarded the job with; `perform_now`
      # writes the run as `discarded` once it returns.
      def record_discard(error)
        @discarded_error = error
      end

      # Wraps Continuable's `continue`.
      def perform
        return if run&.terminal? # cancelled while the job was in the queue

        @resumed = false
        @parked = false
        started! or return # false means skip due to the uniqueness constraints
        yield
        completed! unless @resumed
      rescue Cancelled
        # `Run#cancel!` ended the run; nothing happens after
      end

      # The step's durability wrapper
      def step
        step, options = job.current_step, job.continuation.step_options
        wait!(step, **options.slice(:wait, :wait_until, :await)) if options.values_at(:wait, :wait_until, :await).any?
        step_started!(step, **options.slice(:isolated, :await))
        begin
          yield
          step_completed!(step)
        rescue Exception => error # rubocop:disable Lint/RescueException
          step_stopped!(step, error)
          raise
        end
      ensure
        @step = nil
      end

      # The cursor's durabilty
      def checkpoint!
        return unless run

        if @step && (current = job.continuation.instrumentation[:current_step])
          @step.update_columns(cursor: serialize_cursor(step_cursor(current)))
        end

        attributes = {last_heartbeat_at: Time.current}
        state = self.state
        attributes[:state] = state unless state == @state_written
        write_running!(**attributes)
      end

      def resume!(error)
        raise error if halt?(error)

        @resumed = true
        return false if @parked

        write_running!(state:, resumptions: job.resumptions, last_heartbeat_at: Time.current)
        true
      end

      def halted!(error)
        halt = error.is_a?(Halt)
        write_run(
          if_status: "running",
          status: "halted",
          state:,
          resumptions: job.resumptions,
          parked_job: job.serialize,
          halt_reason: (error.reason&.to_s if halt),
          error_class: (error.class.name unless halt),
          error_message: (error.message unless halt),
          transitioned_at: Time.current
        )
      end

      private

      attr_reader :job

      def config = job.class.durable_config

      def run = @run ||= Run.find_by(active_job_id: job.job_id)

      def halt?(error) = error.is_a?(Halt) || config.halt_error?(error)

      def serialized_progress(run)
        progress = {"completed" => Array(run.completed_steps)}
        if run.current_step && (cursor, _ = Step.where(run_id: run.id, name: run.current_step).order(attempt: :desc).pick(:cursor, :attempt))
          progress["current"] = [run.current_step, cursor_for_continuation(cursor)]
        end
        progress
      end

      def cursor_for_continuation(serialized_cursor)
        if ActiveJob::Continuation.private_method_defined?(:serialized_current)
          serialized_cursor # Rails 8.2+
        else
          Arguments.deserialize([serialized_cursor]).first # Rails <8.2
        end
      end

      # Last write wins, within `if_status:`. False, and nothing written, when the
      # row was not created because another run holds the key (`on_conflict: :skip`).
      def upsert_run!(if_status: nil, **attributes)
        return write_run(if_status:, **attributes) if run

        attributes = {
          job_class: job.class.name,
          key:,
          active_key: (active_key if config.unique?),
          arguments: job.send(:serialize_arguments_if_needed, job.arguments),
          state:,
          transitioned_at: Time.current
        }.merge(attributes)
        run = create_run(attributes) or return false
        @run = run

        if run.previously_new_record?
          @state_written = attributes[:state]
          true
        else
          write_run(if_status:, **attributes)
        end
      end

      # Inserts the row. With `unique_by`, a run holding the same
      # `active_key` decides first, by `on_conflict`; the unique index settles a
      # race between two first enqueues, and the loser looks again, once.
      def create_run(attributes, retried: false)
        Run.transaction(requires_new: true) do
          if config.unique? && (live = Run.find_by(job_class: job.class.name, active_key: attributes[:active_key]))
            resolve_conflict!(live) or next
          end
          Run.create!(active_job_id: job.job_id, **attributes)
        end
      rescue ActiveRecord::RecordNotUnique
        Run.find_by(active_job_id: job.job_id) || (retried ? raise : create_run(attributes, retried: true))
      end

      # True when this run may be inserted.
      def resolve_conflict!(live)
        case config.on_conflict
        when :skip
          @conflict = live
          false
        when :reject
          @conflict = live
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

      def started!
        now = Time.current
        written = upsert_run!(
          if_status: Run::CANCELLABLE_STATUSES,
          status: "running",
          started_at: run&.started_at || now,
          last_heartbeat_at: now,
          resumptions: job.continuation.started? ? job.resumptions + 1 : job.resumptions,
          parked_job: nil,
          transitioned_at: now
        )
        return false if @conflict

        written or raise Cancelled, "Run #{run.id} was cancelled"
      end

      def completed!
        now = Time.current
        write_running!(
          status: "completed",
          current_step: nil,
          active_key: nil,
          state:,
          resumptions: job.resumptions,
          finished_at: now,
          transitioned_at: now
        )
      end

      def failed!(error)
        now = Time.current
        upsert_run!(
          if_status: Run::CANCELLABLE_STATUSES,
          status: "failed",
          state:,
          resumptions: job.resumptions,
          parked_job: job.serialize,
          error_class: error.class.name,
          error_message: error.message,
          finished_at: now,
          transitioned_at: now
        )
      end

      def discarded!(error)
        now = Time.current
        upsert_run!(
          if_status: Run::CANCELLABLE_STATUSES,
          status: "discarded",
          active_key: nil,
          error_class: error.class.name,
          error_message: error.message,
          finished_at: now,
          transitioned_at: now
        )
      end

      def write_run(if_status: nil, **attributes)
        run = self.run or return true

        @state_written = attributes[:state] if attributes.key?(:state)
        scope = Run.where(id: run.id)
        scope = scope.where(status: if_status) if if_status
        scope.update_all(**attributes, updated_at: Time.current).positive?
      end

      def write_running!(**attributes)
        write_run(if_status: "running", **attributes) or raise Cancelled, "Run #{run.id} was cancelled"
      end

      def step_started!(step, isolated:, await:)
        run = self.run or return
        name = step.name.to_s

        @step_await = await
        Run.transaction do
          signals = pending_signals(lock: true)
          attributes = {current_step: name, wake_at: nil}
          if signals.key?(name)
            attributes[:pending_signals] = signals.except(name)
            @await_value = signals[name] if @step_await
          end
          write_running!(**attributes)

          @step = run.steps.create(
            name:,
            position: job.continuation.instrumentation[:completed_steps].size + 1,
            attempt: Step.where(run_id: run.id, name:).maximum(:attempt).to_i + 1,
            status: "started",
            cursor: serialize_cursor(step_cursor(step)),
            isolated:,
            started_at: Time.current
          )
        end
        @deadline = nil
      end

      def step_completed!(step)
        step_row = @step or return
        now = Time.current
        completed_steps = job.continuation.instrumentation[:completed_steps].map(&:to_s) << step.name.to_s
        write_running!(completed_steps:, current_step: nil, state:, last_heartbeat_at: now)

        @step = nil
        step_row.update_columns(status: "completed", cursor: serialize_cursor(step_cursor(step)), finished_at: now)
      end

      def step_stopped!(step, error)
        step_row = @step or return
        @step = nil
        status, error =
          case error
          when ActiveJob::Continuation::Interrupt then "interrupted"
          when Cancelled then "cancelled"
          when Halt then "halted"
          else halt?(error) ? ["halted", error] : ["failed", error]
          end

        step_row.update_columns(
          status:,
          cursor: serialize_cursor(step_cursor(step)),
          error_class: error&.class&.name,
          error_message: error&.message,
          finished_at: Time.current
        )
      end

      # Parks the run when the step's signal has not arrived and its deadline has
      # not passed.
      def wait!(step, wait:, wait_until:, await:)
        run or return
        name = step.name.to_s
        resumed = step.resumed? && !(await && halted?(name))
        @await_value = (step.cursor if resumed) if await
        return if resumed

        status = Run.transaction do
          next if pending_signals(lock: true).key?(name)

          deadline = deadline(name, wait, wait_until)
          next if deadline && deadline <= Time.current

          parked = await ? "awaiting" : "waiting"
          write_running!(
            status: parked, current_step: name, wake_at: deadline, state:, resumptions: job.resumptions,
            parked_job: job.serialize, transitioned_at: Time.current
          )
          @deadline, @deadline_step = deadline, name
          parked
        end
        return unless status

        @parked = true
        job.interrupt!(reason: status.to_sym)
      end

      # A `wait_until:` is read again at every wake; a `wait:` counts from the
      # first time the line is reached and is then kept on the row.
      def deadline(name, wait, wait_until)
        if wait_until
          timer_value(wait_until)
        elsif wait
          (@deadline if @deadline_step == name) || Time.current + timer_value(wait)
        end
      end

      def timer_value(value) = value.respond_to?(:call) ? value.call : value

      def halted?(name) = Step.where(run_id: run.id, name:).order(attempt: :desc).pick(:status) == "halted"

      def pending_signals(lock: false)
        scope = Run.where(id: run.id)
        scope = scope.lock if lock
        scope.pick(:pending_signals) || {}
      end

      # An `await` step's cursor is the signal value, whatever the resumed step carries.
      def step_cursor(step) = @step_await ? @await_value : step.cursor

      def serialize_cursor(cursor) = Arguments.serialize([cursor]).first

      # The attribute values as `ActiveJob::Attributes#serialize` puts them under
      # `"attributes"`. Rails 8.1 has no Attributes.
      def state = job.respond_to?(:serialize_attribute_values, true) ? job.send(:serialize_attribute_values) : {}

      # The run's identity inside the class: either `set(workflow_key:)` or
      # the configured one.
      def key
        return workflow_key if workflow_key
        return Config.digest_key(job.send(:serialize_arguments_if_needed, job.arguments)) if job.send(:arguments_serialized?)

        config.workflow_key(*job.arguments)
      end

      # The identity one run holds at a time: either `set(workflow_key:)` or else
      # the configured one.
      def active_key
        return workflow_key if workflow_key
        return Config.digest_key(job.send(:serialize_arguments_if_needed, job.arguments)) if job.send(:arguments_serialized?)

        config.active_key(*job.arguments)
      end
    end
  end
end
