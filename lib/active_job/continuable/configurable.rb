# frozen_string_literal: true

require "active_job/continuable"

module ActiveJob
  module Continuable
    # = Configurable continuation
    #
    # Continuable with a pluggable continuation class, which receives any extra
    # `step` options along with `start:` and `isolated:`:
    #
    #   class TimedJob < ApplicationJob
    #     include ActiveJob::Continuable::Configurable
    #
    #     self.continuation_class = TimedContinuation
    #
    #     def perform
    #       step :remind, wait: 2.weeks # TimedContinuation#run_step(:remind, start: nil, isolated: false, wait: 2.weeks)
    #     end
    #   end
    module Configurable
      extend ActiveSupport::Concern
      include ActiveJob::Continuable

      # Continuable defines its constructor on the including class, so this one
      # is prepended to the class to run after it.
      module Initializer # :nodoc:
        def initialize(...)
          super
          self.continuation = continuation_class.new(self, {})
        end
      end

      included do
        class_attribute :continuation_class, instance_writer: false, default: ActiveJob::Continuation

        prepend Initializer
      end

      def step(step_name, start: nil, isolated: false, **options, &block)
        block ||= step_method_block(step_name)
        checkpoint! if continuation.advanced?
        continuation.step(step_name, start:, isolated:, **options, &block)
      end

      if Continuable.private_method_defined?(:continuation_serialized?) # Rails 8.2+
        private def deserialize_arguments_if_needed
          serialized, @serialized_continuation = @serialized_continuation, nil
          super
          self.continuation = continuation_class.new(self, serialized) if serialized
        end
      else
        def deserialize(job_data) # :nodoc:
          super
          self.continuation = continuation_class.new(self, job_data.fetch("continuation", {}))
        end
      end

      private

      # The method named after the step, as a step block.
      def step_method_block(step_name)
        step_method = method(step_name)

        raise ArgumentError, "Step method '#{step_name}' must accept 0 or 1 arguments" if step_method.arity > 1

        if step_method.parameters.any? { |type, _name| type == :key || type == :keyreq }
          raise ArgumentError, "Step method '#{step_name}' must not accept keyword arguments"
        end

        (step_method.arity == 0) ? ->(_step) { step_method.call } : step_method
      end
    end
  end
end
