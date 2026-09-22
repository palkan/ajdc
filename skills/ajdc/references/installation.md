# Installing AJ/DC

## 1. The gem

```sh
bundle add ajdc
```

Requirements: Ruby 3.3+, Rails 8.1+ (`attribute` on jobs needs Rails 8.2), SQLite, PostgreSQL or
MySQL, and a queue adapter with a scheduler for the recurring wake job (Solid Queue recurring
tasks, sidekiq-cron, GoodJob cron).

## 2. The tables: one database or two

AJ/DC writes two tables, `active_job_durable_runs` and `active_job_durable_steps`. Decide
where they live before generating anything.

| | Primary database (default) | Separate database |
|---|---|---|
| Command | `bin/rails generate ajdc:install` then `db:migrate` | `bin/rails generate ajdc:install --database=NAME` then `db:prepare` |
| Files | one migration in `db/migrate` | one migration in `db/NAME_migrate`, plus `config/initializers/active_job_durable.rb` |
| `perform_later` inside a transaction | the run row commits with the record that starts it; a rollback removes both | two databases, two transactions: a rollback of the record can leave an `enqueued` run |
| `unique_by` conflicts | decided in the caller's transaction | decided in the durable database's transaction |
| Choose it when | the default; any app where runs start from model callbacks or `with_lock` blocks | the app already keeps `solid_queue`, `solid_cache` in their own databases and wants run rows off the primary; or the primary is not writable from workers |

Recommendation: the primary database unless there is a stated reason. The transaction property
in `transactions.md` §1 depends on it.

### Primary database

```sh
bin/rails generate ajdc:install
bin/rails db:migrate
```

### Separate database

1. Declare the database in `config/database.yml` with its own `migrations_paths`:

   ```yaml
   production:
     primary:
       <<: *default
     durable:
       <<: *default
       database: storage/production_durable.sqlite3     # or the adapter's settings
       migrations_paths: db/durable_migrate
   ```

   Repeat for `development` and `test`.

2. Generate with the database name; the migration lands in that path and the initializer is
   written:

   ```sh
   bin/rails generate ajdc:install --database=durable
   bin/rails db:prepare
   ```

   ```ruby
   # config/initializers/active_job_durable.rb (generated)
   ActiveJob::Durable.connects_to = { database: { writing: :durable } }
   ```

3. In step bodies that start a run from inside a model transaction, guard the first step
   against a record that was rolled back (`return unless record.persisted?`), since the run
   row can exist without it.

## 3. The clock

Timers and signal deadlines are woken by one recurring job. Without it, nothing that waits ever
wakes. Add it to the app's scheduler once:

```yaml
# config/recurring.yml (Solid Queue)
durable_wake:
  class: ActiveJob::Durable::WakeJob
  schedule: every minute
```

sidekiq-cron, GoodJob cron and others: schedule `ActiveJob::Durable::WakeJob.perform_later`
every minute. The interval is the precision of every `wait:`, `wait_until:` and `await`
deadline.

## 4. Verify

```sh
bin/rails runner 'puts ActiveJob::Durable::Run.count'        # 0, no error
bin/rails runner 'puts ActiveJob::Durable.wake_up_due'       # 0, no error
```

Then convert one job: `include ActiveJob::Durable` in place of `ActiveJob::Continuable`, run
its tests, enqueue it once, and read `MyJob.workflow_runs.last`.

## 5. Mission Control

If `mission_control-jobs` is mounted, the runs are plain Active Record rows next to the jobs;
`ActiveJob::Durable::Run` has no UI of its own yet.
