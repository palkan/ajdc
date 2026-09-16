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

    mattr_accessor :connects_to, instance_accessor: false

    # `last_heartbeat_at` is refreshed at most once per interval; the cursor is
    # still committed at every checkpoint.
    HEARTBEAT_INTERVAL = 5.seconds

    # Raised inside `perform_now` when the payload references a run row that does
    # not exist (or belongs to another job), so `retry_on`, `discard_on` and
    # `rescue_from` handlers can see it.
    class RunNotFoundError < StandardError; end

    included do
      class_attribute :durable_identity, instance_writer: false

      # Add our hook before Continuable's `around_perform :continue`,
      # so we can wrap it
      around_perform :durable_perform, prepend: true

      after_discard { |_job, error| @durable_discarded_error = error }
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
        durable_check_identity!(names) if !block && method_defined?(:perform, false)
        self.durable_identity = block || names
      end

      # This class's runs, newest first. `for(*args, **kwargs)` on the relation
      # finds the runs `perform_later(*args, **kwargs)` would have created;
      # `for(workflow_key: "...")` matches a key verbatim.
      def workflow_runs = Run.where(job_class: name).newest_first

      # The key `perform_later(*args, **kwargs)` builds.
      def durable_key_for(...) = new(...).send(:durable_key) # :nodoc:

      def durable_check_identity!(names) # :nodoc:
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
        raise ArgumentError, "identified_by: unknown perform parameter #{unknown.inspect} (perform(#{signature}) has #{known.join(", ")})"
      end
    end

    # Creates the run before the job is handed to the adapter, so that the row is
    # part of the caller's transaction when enqueuing is deferred to after commit.
    # A retry or resume (same `job_id`) finds the row and only updates its status.
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

    # The run must be the only source of truth, so drop the base continuation parameters from the payload.
    def serialize # :nodoc:
      super.except("continuation", "attributes", "resumptions").merge("durable_run_id" => @durable_run&.id)
    end

    def deserialize(job_data) # :nodoc:
      super
      @durable_run_id = job_data["durable_run_id"]
    end

    # A run is `discarded` when Active Job swallowed the error and `failed` when the
    # error is raised to the backend; a retried job is `enqueued` again by `enqueue`.
    def perform_now # :nodoc:
      @durable_discarded_error = nil
      result = super
      durable_run_discarded!(@durable_discarded_error) if @durable_discarded_error
      result
    rescue Exception => err # rubocop:disable Lint/RescueException
      durable_run_failed!(err)
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

    def durable_cursor_for_continuation(serialized_cursor)
      if Continuation.private_method_defined?(:serialized_current)
        serialized_cursor # Rails 8.2+
      else
        Arguments.deserialize([serialized_cursor]).first # Rails <8.2
      end
    end

    def resume_job(exception) # :nodoc:
      @durable_resumed = true
      error = exception.is_a?(Hash) ? exception[:exception] : exception
      if error.is_a?(Continuation::Interrupt)
        durable_step_finished!("interrupted") # Rails 8.2+
      else
        durable_step_finished!("failed", error:) # Rails <8.2
      end
      durable_write_run(state: durable_state, resumptions:, last_heartbeat_at: Time.current)
      super
    end

    # Wraps Continuable's `continue`.
    def durable_perform
      @durable_step = nil
      @durable_resumed = false
      durable_run_started!
      yield
      durable_run_completed! unless @durable_resumed
    rescue Exception => error # rubocop:disable Lint/RescueException
      durable_step_finished!("failed", error:)
      raise
    end

    def durable_run = @durable_run ||= Run.find_by(active_job_id: job_id)

    # Last write wins.
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

    def durable_run_enqueued! = durable_upsert_run!(status: "enqueued", state: durable_state, finished_at: nil, transitioned_at: Time.current)

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
        resumptions:,
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
        resumptions:,
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

    def durable_step_started!(step, isolated)
      run = durable_run or return
      now = Time.current
      name = step.name.to_s

      @durable_step = run.steps.create(
        name:,
        position: continuation.instrumentation[:completed_steps].size + 1,
        attempt: Step.where(run_id: run.id, name:).maximum(:attempt).to_i + 1,
        status: "started",
        cursor: durable_serialize_cursor(step.cursor),
        isolated:,
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
      durable_write_run(completed_steps:, current_step: nil, state: durable_state, last_heartbeat_at: now)
    end

    def durable_step_finished!(status, error: nil)
      step_row = @durable_step or return
      @durable_step = nil
      current = continuation.instrumentation[:current_step]

      step_row.update_columns(
        status:,
        cursor: current ? durable_serialize_cursor(current.cursor) : step_row.cursor,
        error_class: error&.class&.name,
        error_message: error&.message,
        finished_at: Time.current
      )
    end

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

    # The attribute values as `ActiveJob::Attributes#serialize` puts them under
    # `"attributes"`. Rails 8.1 has no Attributes.
    def durable_state = respond_to?(:serialize_attribute_values, true) ? serialize_attribute_values : {}

    def durable_serialize_cursor(cursor) = Arguments.serialize([cursor]).first

    def durable_resumptions = continuation.started? ? resumptions + 1 : resumptions

    # The run's identity inside the class: the `identified_by` components (or every
    # argument) rendered and joined with ":".
    def durable_key
      components = arguments_serialized? ? [] : durable_identity_components
      if components.empty?
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(serialize_arguments_if_needed(arguments)))
      else
        components.map { |component| durable_key_component(component) }.join(":")
      end
    end

    def durable_identity_components
      positional, keywords = durable_split_arguments
      identity = durable_identity

      if identity.is_a?(Proc)
        value = identity.call(*positional, **keywords)
        value.is_a?(Array) ? value : [value]
      elsif identity.present?
        self.class.durable_check_identity!(identity)
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
