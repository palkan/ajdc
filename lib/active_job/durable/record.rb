# frozen_string_literal: true

require "active_record"

module ActiveJob
  module Durable
    # Base class for the gem's records. Can be used to define a custom database to connect to:
    #
    #   ActiveJob::Durable.connects_to = { database: { writing: :durable } }
    class Record < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord
      self.abstract_class = true
      self.strict_loading_by_default = false

      connects_to(**Durable.connects_to) if Durable.connects_to
    end
  end
end
