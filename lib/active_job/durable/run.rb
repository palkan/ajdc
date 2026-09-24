# frozen_string_literal: true

module ActiveJob
  module Durable
    # One row per run of a durable job: from the first enqueue to a terminal status,
    # across every retry, interrupt and resume.
    class Run < Record
      LIVE_STATUSES = %w[enqueued running waiting awaiting].freeze
      ATTENTION_STATUSES = %w[failed halted].freeze
      TERMINAL_STATUSES = %w[completed discarded cancelled].freeze
      STATUSES = (LIVE_STATUSES + ATTENTION_STATUSES + TERMINAL_STATUSES).freeze
      CANCELLABLE_STATUSES = (LIVE_STATUSES + ATTENTION_STATUSES).freeze
      WAKEABLE_STATUSES = %w[waiting awaiting].freeze

      # The `state` column keeps the attribute values in Active Job argument form
      # (the form `ActiveJob::Attributes` restores from), while `Run#state` reads as
      # a plain hash: `{"verdict" => "unsure"}`. Writes accept either form.
      class StateType < ActiveRecord::Type::Json
        def deserialize(value)
          decoded = super
          decoded.present? ? ActiveJob::Arguments.deserialize([decoded]).first : {}
        end

        def serialize(value) = super(self.class.serialized(value))

        # The argument form of `value`; an already-serialized hash (marked with
        # `_aj_` keys) is returned as is.
        def self.serialized(value)
          value = value.to_h
          if value.each_key.any? { |key| key.to_s.start_with?("_aj_") }
            value
          else
            ActiveJob::Arguments.serialize([value]).first
          end
        end
      end

      self.table_name = "active_job_durable_runs"

      has_many :steps, -> { order(:position, :attempt) }, class_name: "ActiveJob::Durable::Step", dependent: :delete_all

      attribute :completed_steps, default: -> { [] }
      attribute :state, StateType.new, default: -> { {} }
      attribute :pending_signals, default: -> { {} }

      scope :newest_first, -> { order(created_at: :desc, id: :desc) }
      scope :live, -> { where(status: LIVE_STATUSES) }
      scope :attention, -> { where(status: ATTENTION_STATUSES) }
      scope :terminal, -> { where(status: TERMINAL_STATUSES) }
      STATUSES.each { |status| scope status, -> { where(status:) } }

      scope :at_step, ->(name) { where(current_step: name.to_s) }
      # A parked run is stuck when its wake time passed and the clock did not wake it.
      scope :stuck_for, ->(duration) {
        since = duration.ago
        where(status: "running").where(last_heartbeat_at: ...since)
          .or(where(status: "enqueued").where(transitioned_at: ...since))
          .or(where(status: WAKEABLE_STATUSES).where(wake_at: ...since))
      }
      scope :due, ->(now = Time.current) { where(status: WAKEABLE_STATUSES, wake_at: ..now) }
      scope :for, ->(*args, **kwargs) {
        next where(key: kwargs[:workflow_key]) if kwargs.key?(:workflow_key)

        job_class = where_values_hash["job_class"] or raise ArgumentError, "for needs a job class; use MyJob.workflow_runs.for(...)"
        where(key: job_class.constantize.durable_config.workflow_key(*args, **kwargs))
      }

      def self.wake_due(now = Time.current)
        due(now).find_each.count { |run| run.reenqueue_parked_job!(from: WAKEABLE_STATUSES) }
      end

      # Deletes the terminal runs that ended before `ended_before`, with their
      # steps, one batch per transaction; returns how many. A terminal row is
      # never written again, so `transitioned_at` is when it ended (and is indexed).
      def self.clear_terminal(ended_before:, batch_size: 1_000)
        terminal.where(transitioned_at: ...ended_before).in_batches(of: batch_size).sum do |batch|
          ids = batch.ids
          transaction do
            Step.where(run_id: ids).delete_all
            where(id: ids).delete_all
          end
        end
      end

      def live? = LIVE_STATUSES.include?(status)

      def attention? = ATTENTION_STATUSES.include?(status)

      def terminal? = TERMINAL_STATUSES.include?(status)

      # The attribute values in the form the job restores them from.
      def serialized_state = StateType.serialized(state)

      # Puts a `halted` or `failed` run back in the queue, in place: the step that
      # stopped re-runs from its cursor as a new attempt, and the step rows keep
      # the earlier attempts with their errors. Raises `NotResumable` for any
      # other status, or when another caller resumed the run first.
      def resume!
        reenqueue_parked_job!(from: ATTENTION_STATUSES) ||
          raise(NotResumable, "Run #{id} is #{reload.status}; only a halted or failed run can be resumed")
        self
      end

      # Ends a run that is not terminal, in one status-guarded update, and returns
      # it reloaded. Never touches the queue: a queued job for a cancelled run
      # performs nothing, a running one stops at its next checkpoint. Raises
      # `NotCancellable` for a terminal run, or when another caller ended it first.
      def cancel!
        now = Time.current
        updated = self.class.where(id:, status: CANCELLABLE_STATUSES).update_all(
          status: "cancelled", active_key: nil, parked_job: nil, finished_at: now, transitioned_at: now, updated_at: now
        )
        raise NotCancellable, "Run #{id} is #{reload.status}; a terminal run cannot be cancelled" if updated.zero?

        reload
      end

      # Delivers a signal: `value` (any JSON value, raw) under `name`. A run
      # parked at that name goes back to the queue and the step runs with the
      # value; any other live run keeps it in `pending_signals` for the `await`
      # to consume when the line is reached. A second signal for the same name
      # overwrites the first. Without a name, the parked step is the one woken:
      # a timer ends now, an `await` receives `nil`. Raises `NotLive` when the run
      # is not live, `NotWaiting` for a nameless wake of a run that is not parked.
      # The row lock makes a signal and the job's own park or consume atomic.
      def wake_up(name = nil, value = nil)
        transaction do
          lock!
          unless name
            WAKEABLE_STATUSES.include?(status) or raise NotWaiting, "Run #{id} is #{status}; only a waiting or awaiting run can be woken up"
            name = current_step
          end
          live? or raise NotLive, "Run #{id} is #{status}; a signal needs a live run"

          signals = pending_signals.merge(name.to_s => value)
          if WAKEABLE_STATUSES.include?(status) && current_step == name.to_s
            reenqueue_parked_job!(from: status, pending_signals: signals)
          else
            self.class.where(id:, status:).update_all(pending_signals: signals, updated_at: Time.current)
            reload
          end
        end
        self
      end

      # One status-guarded transition to `enqueued`, then the parked job goes
      # back to the queue once every open transaction has committed. False when
      # the status was not in `from` any more (a concurrent resume, a cancel).
      def reenqueue_parked_job!(from:, **changes) # :nodoc:
        now = Time.current
        updated = self.class.where(id:, status: from).update_all(
          status: "enqueued", error_class: nil, error_message: nil, halt_reason: nil,
          finished_at: nil, transitioned_at: now, updated_at: now, **changes
        )
        return false if updated.zero?

        reload
        job = ActiveJob::Base.deserialize(parked_job)
        job.scheduled_at = nil # a retry's or a resume's delay does not carry over
        ActiveRecord.after_all_transactions_commit { job.enqueue }
        true
      end
    end
  end
end
