[![Gem Version](https://badge.fury.io/rb/ajdc.svg)](https://rubygems.org/gems/ajdc)
[![Build](https://github.com/palkan/ajdc/workflows/Build/badge.svg)](https://github.com/palkan/ajdc/actions)

# AJ/DC: Active Job Durable Continuation

<img align="right" height="150" width="292"
     title="AJ/DC logo" src="./assets/logo.png">

AJ/DC makes an `ActiveJob::Continuable` job's run and steps durable: they're recorded in the database, not only in the job payload, so progress survives a crash, not only a graceful restart.

## Installation

Add to your project's Gemfile:

```ruby
# Gemfile
gem "ajdc"
```

or run `bundle add ajdc`.

Then generate the two tables AJ/DC writes to (`active_job_durable_runs`, `active_job_durable_steps`):

```sh
bin/rails generate ajdc:install
```

This creates a migration and a schema file; apply whichever fits your setup and delete the other:

- **Single database.** Run the generated migration with `bin/rails db:migrate` and delete `db/durable_schema.rb`.
- **Separate database.** Add a `durable` database to `config/database.yml` with `migrations_paths: db/durable_migrate`, point AJ/DC at it, run `bin/rails db:prepare`, and delete the generated migration:

  ```ruby
  # config/initializers/active_job_durable.rb
  ActiveJob::Durable.connects_to = { database: { writing: :durable } }
  ```

### Requirements

- Ruby (MRI) >= 3.3
- Rails >= 8.1 (`ActiveJob::Attributes` needs Rails 8.2)
- SQLite / PostgreSQL / MySQL

## Usage

Include `ActiveJob::Durable` instead of `ActiveJob::Continuable`. `step`, cursors and `attribute` keep working exactly as they do today:

```ruby
# before
class ImportJob < ApplicationJob
  include ActiveJob::Continuable

  attribute :processed_count, :integer, default: 0

  def perform(import)
    step :validate
    step :process do |step|
      import.records.find_each(start: step.cursor) do |record|
        record.process!
        self.processed_count += 1
        step.advance! from: record.id
      end
    end
  end
end
```

```ruby
# after
class ImportJob < ApplicationJob
  include ActiveJob::Durable

  attribute :processed_count, :integer, default: 0

  def perform(import)
    step :validate
    step :process do |step|
      import.records.find_each(start: step.cursor) do |record|
        record.process!
        self.processed_count += 1
        step.advance! from: record.id
      end
    end
  end
end
```

Every checkpoint commits the run and the current step's cursor to the database, so a `SIGKILL` loses at most the work since the last checkpoint.

The run and its steps are plain Active Record models:

```ruby
run = ActiveJob::Durable::Run.last
run.status           # => "completed"
run.current_step     # => nil
run.completed_steps  # => ["validate", "process"]
run.state            # => {"processed_count" => 128}
run.steps.map(&:name) # => ["validate", "process"]
```

### Uniqueness

TBD

### Reading runs

A job class knows its runs, newest first. `workflow_runs` is an Active Record relation, so the scopes below chain onto it:

```ruby
ImportJob.workflow_runs
ImportJob.workflow_runs.failed.at_step(:process)
```

`for` finds the runs `perform_later` would have created with the same arguments; it derives the key the same way. `for(workflow_key:)` matches a key verbatim:

```ruby
ImportJob.workflow_runs.for(import)                       # same key as ImportJob.perform_later(import)
ImportJob.workflow_runs.for(workflow_key: "imports/42")
ImportJob.workflow_runs.for(import).live.first            # the run in progress, or nil
```

Without a declaration, every argument is part of the key: positional arguments in order, then keywords sorted by name as `name=value`. A record renders as `collection/id`; a value that is not a string, symbol, number or boolean becomes a short digest:

```ruby
ImportJob.perform_later(import, "csv", strict: true)      # key "imports/42:csv:strict=true"
```

`identified_by` narrows the key to the named `perform` parameters, positional or keyword:

```ruby
class ImportJob < ApplicationJob
  include ActiveJob::Durable

  identified_by :import   # key "imports/42", whatever the other arguments

  def perform(import, format = "csv", strict: false)
    # ...
  end
end
```

The block form receives the `perform` arguments and returns one component or an array of them:

```ruby
identified_by { |import, **kwargs| [import, kwargs.fetch(:format, "csv")] }   # key "imports/42:csv"
```

A name that is not a `perform` parameter raises `ArgumentError`: at the declaration when the class already defines `perform`, otherwise at the first `perform_later`.

`set(workflow_key:)` names one run's key verbatim, whatever the class derives. It is an enqueue option like `wait:` or `queue:`, so it works with `perform_later`, `perform_now` and `perform_all_later`:

```ruby
ImportJob.set(workflow_key: "imports/42/retry-3", queue: "low").perform_later(import)
ImportJob.workflow_runs.for(workflow_key: "imports/42/retry-3")
```

Other usefule scopes:

```ruby
MyJob.workflow_runs.live  # enqueued, running, waiting, awaiting
MyJob.workflow_runs.at_step(:process)
MyJob.workflow_runs.stuck_for(1.hour)
MyJob.workflow_runs.newest_first
```

A run's `status` says where the job is. `enqueued`: the job is in the queue, written at the first enqueue and at every re-enqueue (an isolated step, a graceful-stop interrupt, a resume after an error, a `retry_on` retry). `running`: a worker is executing it. `started_at` is set once, at the first execution, so an `enqueued` run with no `started_at` never ran. `stuck_for` reads `enqueued` runs by `transitioned_at` and `running` runs by `last_heartbeat_at`.

### Halting

Halting allows you to pause the execution on an error that could be resolved by a human (or alike), so the run could be restarted later from the current step/cursor (e.g., a plan out of storage, a file to fix by hand). Use `halt_on` or `halt!` to stop the run but keep it resumeable (unlike `discard_on`):

```ruby
class ImportJob < ApplicationJob
  include ActiveJob::Durable

  discard_on ZipFile::InvalidFileError
  halt_on InsufficientStorageSpaceError

  def perform(import)
    step :check
    step :process
  end
end
```

The run's status is `halted`; `error_class` and `error_message` hold the error, `current_step` names the step and its row keeps the cursor.

`halt!(reason)` does the same from inside a step, without an error; the reason lands in `halt_reason`:

```ruby
step :run do |step|
  until chat.complete?
    chat.step
    halt!(:tool_approval) if chat.awaiting_approval?
    step.checkpoint!
  end
end
```

```ruby
ImportJob.workflow_runs.halted.first.halt_reason  # => "tool_approval"
```

A halted (or failed) run is resumed in place: `resume!` puts the job back in the queue, the step that stopped re-runs from its cursor as a new attempt, and the earlier attempts keep their errors. Any other status raises `ActiveJob::Durable::NotResumable`.

```ruby
ImportJob.workflow_runs.halted.first.resume!
```

### Cancelling

`cancel!` ends a run that is not terminal: the row becomes `cancelled` and the queue is left alone. A queued job for a cancelled run performs nothing; a running job stops at its next checkpoint or step boundary, and the open step row is `cancelled` with its cursor. A terminal run raises `ActiveJob::Durable::NotCancellable`.

```ruby
ImportJob.workflow_runs.for(import).live.sole.cancel!
```

### Step callbacks

`before_step`, `after_step` and `around_step` are Active Job callbacks, like `before_perform` and friends, for every step that runs; a step skipped on resume triggers none. `after_step` runs only when the step completes. `current_step` is the running `ActiveJob::Continuation::Step`:

```ruby
class Cable::DiagnosticJob < ApplicationJob
  include ActiveJob::Durable

  after_step :broadcast_update
  around_step { |job, block| Rails.logger.tagged(job.current_step.name, &block) }

  def perform(cable)
    @cable = cable
    step :provider_status, isolated: true
    step :websocket_status, isolated: true
    step :admin_api_status, isolated: true
  end

  private
    def broadcast_update
      @cable.broadcast_replace(partial: "cables/diagnostic", locals: { step: current_step.name })
    end
end
```

### Timers

TBD

### Signals

TBD

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/palkan/ajdc](https://github.com/palkan/ajdc).

## Credits

This gem is generated via [`newgem` template](https://github.com/palkan/newgem) by [@palkan](https://github.com/palkan).

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
