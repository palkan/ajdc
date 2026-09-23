# frozen_string_literal: true

module ActiveJob
  module Durable
    # A durable job class's configuration: what identifies its runs, what keeps
    # them unique, which errors halt them, how to generate workflow keys.
    class Config # :nodoc:
      ON_CONFLICT = %i[skip reject replace].freeze

      attr_reader :identity, :uniqueness, :on_conflict, :halt_errors

      def initialize(job_class)
        @job_class = job_class
        @identity = nil
        @uniqueness = nil
        @on_conflict = :skip
        @halt_errors = []
      end

      def initialize_copy(other)
        super
        @identity = @identity.dup
        @uniqueness = @uniqueness.dup
        @halt_errors = @halt_errors.dup
        @args_mapper = nil
      end

      # A copy for a subclass.
      def inherit(job_class) = dup.tap { |copy| copy.job_class = job_class }

      def identified_by(*names, &block)
        @identity = block || names
        @args_mapper = nil
      end

      def unique_by(*names, on_conflict: :skip, &block)
        unless ON_CONFLICT.include?(on_conflict)
          raise ArgumentError, "unique_by: on_conflict must be one of #{ON_CONFLICT.map(&:inspect).join(", ")}, got #{on_conflict.inspect}"
        end

        @uniqueness = block || names
        @on_conflict = on_conflict
        @args_mapper = nil
      end

      def halt_on(*errors) = @halt_errors += errors

      def halt_error?(error) = halt_errors.any? { |klass| error.is_a?(klass) }

      def unique? = !uniqueness.nil?

      # The run's identity inside the class: the `identified_by` components (else
      # the `unique_by` ones, else every argument) joined with ":".
      def workflow_key(...) = build_key((identity || !uniqueness) ? identity : uniqueness, ...)

      # The identity one run holds at a time: the `unique_by` components.
      def active_key(...) = build_key(uniqueness, ...)

      # A key for arguments that are not deserialized yet.
      def self.digest_key(serialized_arguments) = Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(serialized_arguments))

      protected

      attr_writer :job_class

      private

      attr_reader :job_class

      # The named components are checked against `perform` when a key is first
      # built; an unknown name raises on every key until it is fixed.
      def args_mapper
        @args_mapper ||= ArgsMapper.new(job_class, :perform).tap do |mapper|
          mapper.check!([identity, uniqueness].select { |schema| schema.is_a?(Array) }.flatten)
        end
      end

      def build_key(schema, *args, **kwargs)
        components = args_mapper.map(schema, *args, **kwargs)
        if components.empty?
          self.class.digest_key(Arguments.serialize(kwargs.empty? ? args : [*args, Hash.ruby2_keywords_hash(kwargs)]))
        else
          components.map { |component| build_key_component(component) }.join(":")
        end
      end

      def build_key_component(value)
        case value
        when ArgsMapper::Keyword then "#{value.name}=#{build_key_component(value.value)}"
        when GlobalID::Identification
          collection = value.respond_to?(:model_name) ? value.model_name.collection : ActiveModel::Name.new(value.class).collection
          "#{collection}/#{value.id}"
        when Symbol, String, Integer, Float, true, false then value.to_s
        when nil then ""
        else Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(Arguments.serialize([value])))[0, 16]
        end
      end
    end
  end
end
