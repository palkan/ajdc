[![Gem Version](https://badge.fury.io/rb/ajdc.svg)](https://rubygems.org/gems/ajdc)
[![Build](https://github.com/palkan/ajdc/workflows/Build/badge.svg)](https://github.com/palkan/ajdc/actions)

# AJ/DC: Active Job Durable Continuation

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

`status` is one of `enqueued`, `running`, `completed`, `failed`, `discarded`. `discarded` means Active Job handled the error (`discard_on`, or a `retry_on` that ran out of attempts and had a block); `failed` means the error was raised to the queue backend.

### Uniqueness

TBD

### Reading runs

TBD

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
