# frozen_string_literal: true

module ActiveJob
  module Durable
    # One row per step attempt. A step that is interrupted or fails and then re-enters
    # gets a new row with the next `attempt`; `cursor` is the last committed cursor of
    # that attempt, in Active Job argument serialization form.
    class Step < Record
      self.table_name = "active_job_durable_steps"

      belongs_to :run, class_name: "ActiveJob::Durable::Run"
    end
  end
end
