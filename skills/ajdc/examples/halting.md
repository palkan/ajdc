# Halting: an error a person fixes, then the run continues

## Before: rescue inside the step, a status column, a restart from scratch

The shape from Spree's CSV import: `discard_on` would never see an error raised after progress,
so the step rescues, marks the import failed, and stops. A retry starts the job over.

```ruby
class Imports::ProcessJob < ApplicationJob
  include ActiveJob::Continuable

  def perform(import)
    @import = import
    step :create_rows, start: 1
    return if @csv_failed
    step :dispatch_row_groups
  end

  private
    def create_rows(step)
      CSV.foreach(@import.file, headers: true).with_index(1) do |row, number|
        next if number < step.cursor
        ImportRow.create!(import: @import, number:, data: row.to_h)
        step.set!(number)
      end
    rescue StorageQuotaExceeded, CSV::MalformedCSVError => e
      @import.update_columns(status: :failed, processing_errors: e.message)
      @csv_failed = true
    end
end

# admin "Retry": import.update!(status: :pending); Imports::ProcessJob.perform_later(import)   # from row 1
```

## After: `halt_on`, `resume!` from the cursor

```ruby
class Imports::ProcessJob < ApplicationJob
  include ActiveJob::Durable

  discard_on CSV::MalformedCSVError          # nothing can fix the file
  halt_on StorageQuotaExceeded               # a person upgrades the plan, then the run continues

  def perform(import)
    @import = import
    step :create_rows, start: 1
    step :dispatch_row_groups
  end

  private
    def create_rows(step)
      CSV.foreach(@import.file, headers: true).with_index(1) do |row, number|
        next if number < step.cursor
        ImportRow.create!(import: @import, number:, data: row.to_h)
        step.set!(number)
      end
    end
end

# after the plan upgrade:
run = Imports::ProcessJob.workflow_runs.for(import).halted.sole
run.error_class         # => "StorageQuotaExceeded"
run.current_step        # => "create_rows"
run.resume!             # continues from the last committed row number
```

Three verbs for three kinds of failure: `retry_on` is the machine trying again, `discard_on` is
giving up, `halt_on` is a person deciding. The rescue, the flag and the status column are gone;
the import's own facts stay on the import. A halted run is in `workflow_runs.attention` with its
error until someone resumes or cancels it.

## `halt!`: the same stop without an exception

```ruby
def check(name)
  result = public_send(:"check_#{name}")
  self.error_msg = result.reason
  halt!(result.level) unless result.level == :success      # halt_reason = "warning" / "critical"
  metadata[name] = result.data
end
```

`resume!` re-runs the halted step. Use `halt!` when the stop is a decision, not an error; use
`await` instead when the decision carries a value the run needs (see `signals.md`).
