# frozen_string_literal: true

module ActiveJob
  module Durable
    # Maps a method's arguments to its parameters
    class ArgsMapper # :nodoc:
      Keyword = Struct.new(:name, :value)

      def initialize(owner, method_name)
        @owner = owner
        @method_name = method_name
      end

      def check!(names)
        unknown = names - known
        raise ArgumentError, "unknown #{method_name} identifier parameters #{unknown.inspect} (#{method_name} has #{known.join(", ")})" if unknown.any?
      end

      def map(schema, *args, **kwargs)
        if schema.is_a?(Proc)
          value = schema.call(*args, **kwargs)
          value.is_a?(Array) ? value : [value]
        elsif schema.present?
          schema.map { |name| (index = positional_names.index(name)) ? args[index] : kwargs[name] }
        else
          args + kwargs.sort_by { |name, _| name.to_s }.map { |name, value| Keyword.new(name, value) }
        end
      end

      private

      attr_reader :owner, :method_name

      def parameters = @parameters ||= owner.instance_method(method_name).parameters

      def positional_names = @positional_names ||= parameters.filter_map { |type, name| name if type == :req || type == :opt }

      def known = @known ||= parameters.filter_map { |type, name| name if %i[req opt key keyreq].include?(type) }
    end
  end
end
