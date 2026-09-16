# frozen_string_literal: true

module ActiveJob
  module Durable
    # One row per run of a durable job: from the first enqueue to a terminal status,
    # across every retry, interrupt and resume. Found by +active_job_id+.
    class Run < Record
      self.table_name = "active_job_durable_runs"

      has_many :steps, class_name: "ActiveJob::Durable::Step", dependent: :delete_all

      attribute :completed_steps, default: -> { [] }
      attribute :state, default: -> { {} }
      attribute :pending_signals, default: -> { {} }
    end
  end
end
