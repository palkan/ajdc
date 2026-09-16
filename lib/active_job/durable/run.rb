# frozen_string_literal: true

module ActiveJob
  module Durable
    # One row per run of a durable job: from the first enqueue to a terminal status,
    # across every retry, interrupt and resume. Found by +active_job_id+.
    class Run < Record
      # The +state+ column keeps the attribute values in Active Job argument form
      # (the form +ActiveJob::Attributes+ restores from), while +Run#state+ reads as
      # a plain hash: <tt>{"verdict" => "unsure"}</tt>. Writes accept either form.
      class StateType < ActiveRecord::Type::Json
        def deserialize(value)
          decoded = super
          decoded.present? ? ActiveJob::Arguments.deserialize([decoded]).first : {}
        end

        def serialize(value)
          super(self.class.serialized(value))
        end

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

      has_many :steps, class_name: "ActiveJob::Durable::Step", dependent: :delete_all

      attribute :completed_steps, default: -> { [] }
      attribute :state, StateType.new, default: -> { {} }
      attribute :pending_signals, default: -> { {} }

      def serialized_state # :nodoc:
        StateType.serialized(state)
      end
    end
  end
end
