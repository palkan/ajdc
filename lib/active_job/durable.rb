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
  # ActiveJob::Continuable:
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
  # Steps, cursors and attributes behave exactly as in ActiveJob::Continuable,
  # but the run row is the single source of truth: the job payload carries
  # +"durable_run_id"+ instead of the +"continuation"+, +"attributes"+ and
  # +"resumptions"+ keys, and every execution rebuilds the Continuation, the
  # attribute values and the resumption count from +active_job_durable_runs+ and
  # the current attempt in +active_job_durable_steps+. The rows are written
  # before the job is re-enqueued, in every path. The class patches the following
  # Active Job methods:
  #
  # * +enqueue+ creates the run (inside the caller's transaction) or, on a retry
  #   or resume, marks it +enqueued+ again and commits the attribute values;
  # * an +around_perform+ callback wrapping Continuable's +continue+ marks the
  #   run +running+, then +completed+;
  # * +step+ records a step row when the body starts and completes it when the
  #   body returns;
  # * +checkpoint!+ commits the current cursor and the attribute values;
  # * +resume_job+ closes the step row as +interrupted+ (or +failed+) and commits
  #   the attribute values before the job is re-enqueued;
  # * +perform_now+ marks the run +discarded+ when Active Job swallowed the error
  #   (+discard_on+, an exhausted +retry_on+ with a block) and +failed+ when the
  #   error is raised to the queue backend.
  module Durable
    extend ActiveSupport::Concern
    include ActiveJob::Continuable

    autoload :Record, "active_job/durable/record"
    autoload :Run, "active_job/durable/run"
    autoload :Step, "active_job/durable/step"

    # Database configuration for the durable tables, see ActiveJob::Durable::Record.
    mattr_accessor :connects_to, instance_accessor: false

    # +last_heartbeat_at+ is refreshed at most once per interval; the cursor is
    # still committed at every checkpoint.
    HEARTBEAT_INTERVAL = 5.seconds

    # Raised inside +perform_now+ when the payload references a run row that does
    # not exist (or belongs to another job), where +retry_on+, +discard_on+ and
    # +rescue_from+ handlers can see it.
    class RunNotFoundError < StandardError; end

    included do
      # Continuable registers +around_perform :continue+ when it is included, before
      # this block runs. Callback chains run the first registered around callback
      # outermost, so prepending is what makes this callback wrap +continue+: an
      # interrupt or a resumable error is handled inside, and only what escapes
      # +continue+ is a failure.
      around_perform :durable_perform, prepend: true

      # Active Job runs these for every exception that leaves +perform_now+, not
      # only for +discard_on+ (ActiveJob::Execution#perform_now); +perform_now+
      # below decides between +discarded+ and +failed+ once the outcome is known.
      after_discard { |_job, error| @durable_discarded_error = error }
    end

    # Creates the run before the job is handed to the adapter, so that the row is
    # part of the caller's transaction when enqueuing is deferred to after commit.
    # A retry or resume (same +job_id+) finds the row and only updates its status.
    def enqueue(options = {})
      durable_run_enqueued!
      super
    end

    def step(step_name, start: nil, isolated: false, &block)
      block ||= durable_step_method(step_name)

      super do |step|
        durable_step_started!(step, isolated)
        block.call(step)
        durable_step_completed!(step)
      end
    end

    def checkpoint! # :nodoc:
      durable_checkpoint!
      super
    end

    # The payload references the run instead of carrying progress and attributes.
    # +durable_run_id+ is +nil+ for a job serialized before any row exists (built
    # but never enqueued, or bulk-enqueued): such a job starts fresh and its row is
    # created when it performs.
    def serialize # :nodoc:
      super.except("continuation", "attributes", "resumptions").merge("durable_run_id" => @durable_run&.id)
    end

    def deserialize(job_data) # :nodoc:
      super
      @durable_run_id = job_data["durable_run_id"]
    end

    # A run is +discarded+ when Active Job swallowed the error and +failed+ when the
    # error is raised to the backend; a retried job is +enqueued+ again by +enqueue+.
    def perform_now # :nodoc:
      @durable_discarded_error = nil
      result = super
      durable_run_discarded!(@durable_discarded_error) if @durable_discarded_error
      result
    rescue Exception => error # rubocop:disable Lint/RescueException -- same as ActiveJob::Execution#perform_now; re-raised
      durable_run_failed!(error)
      raise
    end

    private

    # Continuable builds the Continuation here rather than in +deserialize+, so
    # that a cursor that fails to deserialize raises inside +perform_now+ where the
    # job's error handlers run. The row is read at the same point for the same
    # reason: a missing row raises RunNotFoundError there. Without a run id (see
    # +serialize+) Continuable's own payload handling is left alone.
    def deserialize_arguments_if_needed
      super
      durable_restore_from_run! if @durable_run_id
    end

    # Rebuilds what Continuable and Attributes used to read from the payload: the
    # +{"completed" => [...], "current" => [name, serialized_cursor]}+ shape from the
    # run and its current step attempt, the attribute values from +state+, and
    # +resumptions+.
    def durable_restore_from_run!
      run_id, @durable_run_id = @durable_run_id, nil
      run = Run.find_by(id: run_id, active_job_id: job_id)
      raise RunNotFoundError, "Run #{run_id} for #{self.class.name} (Job ID: #{job_id}) was not found" unless run

      @durable_run = run
      @durable_state_written = run.serialized_state
      self.resumptions = run.resumptions
      self.continuation = Continuation.new(self, durable_serialized_progress(run))
      if run.state.present? && respond_to?(:deserialize_attribute_values, true)
        deserialize_attribute_values(run.serialized_state)
      end
    end

    def durable_serialized_progress(run)
      progress = {"completed" => Array(run.completed_steps)}
      if run.current_step
        cursor = Step.where(run_id: run.id, name: run.current_step).order(attempt: :desc).pick(:cursor)
        progress["current"] = [run.current_step, durable_cursor_for_continuation(cursor)]
      end
      progress
    end

    # Step rows hold the cursor in Active Job argument form. Since Rails 8.2
    # (rails/rails#58045) Continuation deserializes the current cursor itself;
    # 8.1 expects the plain value.
    def durable_cursor_for_continuation(serialized_cursor)
      if Continuation.private_method_defined?(:serialized_current)
        serialized_cursor
      else
        Arguments.deserialize([serialized_cursor]).first
      end
    end

    # Rails 8.1's +continue+ calls +resume_job(exception: e)+ on the error-resume
    # path, which lands in the positional parameter as +{exception: e}+; main
    # passes the exception positionally (rails/rails@aa159a7e). The argument goes
    # to +super+ unchanged.
    def resume_job(exception) # :nodoc:
      @durable_resumed = true
      error = exception.is_a?(Hash) ? exception[:exception] : exception
      if error.is_a?(Continuation::Interrupt)
        durable_step_finished!("interrupted")
      else
        durable_step_finished!("failed", error: error)
      end
      durable_write_run(state: durable_state, resumptions: resumptions, last_heartbeat_at: Time.current)
      super
    end

    # Wraps Continuable's +continue+: a normal return is a completed run unless
    # +resume_job+ ran; an error escaping +continue+ closes the open step row and is
    # left to +perform_now+, which knows whether Active Job handles it.
    def durable_perform
      @durable_step = nil
      @durable_resumed = false
      durable_run_started!
      yield
      durable_run_completed! unless @durable_resumed
    rescue Exception => error # rubocop:disable Lint/RescueException -- re-raised
      durable_step_finished!("failed", error: error)
      raise
    end

    # Run row

    def durable_run
      @durable_run ||= Run.find_by(active_job_id: job_id)
    end

    # Writes +attributes+ to the run found by +active_job_id+, or creates the run with
    # them. The unique index is the arbiter of a concurrent first insert: the loser
    # finds the winner's row and writes to it.
    def durable_upsert_run!(**attributes)
      if durable_run
        durable_write_run(**attributes)
        return durable_run
      end

      attributes = {
        job_class: self.class.name,
        key: durable_key,
        arguments: serialize_arguments_if_needed(arguments),
        state: durable_state,
        transitioned_at: Time.current
      }.merge(attributes)
      run = Run.create_or_find_by!(active_job_id: job_id) do |new_run|
        new_run.assign_attributes(attributes)
      end
      @durable_run = run

      if run.previously_new_record?
        @durable_state_written = attributes[:state]
        @durable_heartbeat_at = attributes[:last_heartbeat_at]
      else
        durable_write_run(**attributes)
      end
      run
    end

    # Also called by +retry_job+ (+retry_on+, +resume_job+): the attribute values
    # must be in the row before the adapter serializes the job.
    def durable_run_enqueued!
      durable_upsert_run!(status: "enqueued", state: durable_state, finished_at: nil, transitioned_at: Time.current)
    end

    def durable_run_started!
      now = Time.current
      durable_upsert_run!(
        status: "running",
        started_at: durable_run&.started_at || now,
        last_heartbeat_at: now,
        resumptions: durable_resumptions,
        transitioned_at: now
      )
    end

    def durable_run_completed!
      now = Time.current
      durable_write_run(
        status: "completed",
        current_step: nil,
        active_key: nil,
        state: durable_state,
        resumptions: resumptions,
        finished_at: now,
        transitioned_at: now
      )
    end

    def durable_run_failed!(error)
      now = Time.current
      durable_upsert_run!(
        status: "failed",
        active_key: nil,
        state: durable_state,
        resumptions: resumptions,
        error_class: error.class.name,
        error_message: error.message,
        finished_at: now,
        transitioned_at: now
      )
    end

    def durable_run_discarded!(error)
      now = Time.current
      durable_upsert_run!(
        status: "discarded",
        active_key: nil,
        error_class: error.class.name,
        error_message: error.message,
        finished_at: now,
        transitioned_at: now
      )
    end

    # One UPDATE, no callbacks or validations.
    def durable_write_run(**attributes)
      return unless durable_run

      @durable_state_written = attributes[:state] if attributes.key?(:state)
      @durable_heartbeat_at = attributes[:last_heartbeat_at] if attributes.key?(:last_heartbeat_at)
      durable_run.update_columns(**attributes, updated_at: Time.current)
    end

    # Step rows

    def durable_step_started!(step, isolated)
      run = durable_run or return
      now = Time.current
      name = step.name.to_s

      @durable_step = Step.create!(
        run: run,
        name: name,
        position: continuation.instrumentation[:completed_steps].size + 1,
        attempt: Step.where(run_id: run.id, name: name).maximum(:attempt).to_i + 1,
        status: "started",
        cursor: durable_serialize_cursor(step.cursor),
        isolated: isolated,
        started_at: now
      )
      durable_write_run(current_step: name)
    end

    def durable_step_completed!(step)
      step_row = @durable_step or return
      @durable_step = nil
      now = Time.current

      step_row.update_columns(status: "completed", cursor: durable_serialize_cursor(step.cursor), finished_at: now)
      completed_steps = continuation.instrumentation[:completed_steps].map(&:to_s) << step.name.to_s
      durable_write_run(completed_steps: completed_steps, current_step: nil, state: durable_state, last_heartbeat_at: now)
    end

    # Closes the open step row, if any, as +interrupted+ or +failed+ with its last cursor.
    def durable_step_finished!(status, error: nil)
      step_row = @durable_step or return
      @durable_step = nil
      current = continuation.instrumentation[:current_step]

      step_row.update_columns(
        status: status,
        cursor: current ? durable_serialize_cursor(current.cursor) : step_row.cursor,
        error_class: error&.class&.name,
        error_message: error&.message,
        finished_at: Time.current
      )
    end

    # Called from Continuable's +checkpoint!+ before it decides whether to interrupt:
    # the step row gets the cursor; the run row gets the attribute values when they
    # changed and a heartbeat when the previous one is older than HEARTBEAT_INTERVAL.
    def durable_checkpoint!
      return unless durable_run

      now = Time.current
      if @durable_step && (current = continuation.instrumentation[:current_step])
        @durable_step.update_columns(cursor: durable_serialize_cursor(current.cursor))
      end

      attributes = {}
      state = durable_state
      attributes[:state] = state unless state == @durable_state_written
      if @durable_heartbeat_at.nil? || @durable_heartbeat_at <= now - HEARTBEAT_INTERVAL
        attributes[:last_heartbeat_at] = now
      end
      durable_write_run(**attributes) if attributes.any?
    end

    # Values

    # The attribute values in the form ActiveJob::Attributes#serialize puts under
    # +"attributes"+. Rails 8.1 has Continuable without Attributes: empty then.
    def durable_state
      respond_to?(:serialize_attribute_values, true) ? serialize_attribute_values : {}
    end

    def durable_serialize_cursor(cursor)
      Arguments.serialize([cursor]).first
    end

    # Continuable increments +resumptions+ inside +continue+, which runs inside
    # this module's callback; this is the value the execution is about to have.
    def durable_resumptions
      continuation.started? ? resumptions + 1 : resumptions
    end

    # Default identity: the GlobalID-able arguments as +collection/id+, joined with
    # +:+ ("cards/42:users/7"); a SHA256 of the serialized arguments otherwise.
    def durable_key
      serialized = serialize_arguments_if_needed(arguments)
      records = arguments_serialized? ? [] : arguments.grep(GlobalID::Identification)

      if records.any?
        records.map { |record| "#{durable_collection_name(record)}/#{record.id}" }.join(":")
      else
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(serialized))
      end
    end

    def durable_collection_name(record)
      if record.respond_to?(:model_name)
        record.model_name.collection
      else
        ActiveModel::Name.new(record.class).collection
      end
    end

    # The method form of +step+, resolved with Continuable's rules (0 or 1
    # positional argument, no keywords), so that the body can be wrapped.
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
