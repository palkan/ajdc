# frozen_string_literal: true

module JobBuffer
  class << self
    def clear = values.clear

    def add(value) = values << value

    def values = @values ||= []

    def last_value = values.last
  end
end

class ActiveSupport::TestCase
  teardown do
    JobBuffer.clear
  end
end
