# Testing durable workflows

## 1. Setup

```ruby
class ImportJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper                      # perform_enqueued_jobs, assert_enqueued_jobs
  include ActiveJob::Continuation::TestHelper        # interrupt_job_during_step / after_step (Rails 8.1)

end
```

- Queue adapter `:test`. Use the block form, `perform_enqueued_jobs do ... end`: it performs
  every job enqueued inside the block, including the re-enqueues at isolated steps, interrupts
  and resumes, so a durable run executes until it parks, halts, fails or completes. Do not count
  executions.
- Freeze time with `travel_to`; timers compare `wake_at` with `Time.current`.
- Each test starts from an empty runs table (`Run.delete_all` in setup if fixtures are not
  transactional for the durable database).

## 2. Drive a run to its next park

```ruby
perform_enqueued_jobs { ImportJob.perform_later(import) }   # runs through every step and re-enqueue

run = ImportJob.workflow_runs.for(import).sole
assert_equal "completed", run.status
assert_equal %w[check process], run.completed_steps
assert_equal "imported", import.reload.state                 # the logic, first of all
```

Assert the outcome on your models, then the run's `status` and `completed_steps`. Do not
assert what happens between executions; that is the gem's business.

## 3. Crash and resume (the SIGKILL test)

Make a step fail once after progress, then assert the cursor and the resume:

```ruby
stub_import_to_fail_on("c")                    # your own stub, once
perform_enqueued_jobs { ImportJob.perform_later(import, %w[a b c d e]) }

run = ImportJob.workflow_runs.for(import).sole
assert_equal "failed", run.status
assert_equal %w[a b], import.reload.imported_items

perform_enqueued_jobs { run.resume! }
assert_equal %w[a b c d e], import.reload.imported_items     # c, d, e once; a, b not twice
assert_equal "completed", run.reload.status
```

Graceful interrupt (deploy), Rails' own helper:

```ruby
perform_enqueued_jobs do
  interrupt_job_during_step(ImportJob, :process, cursor: 2) { ImportJob.perform_later(import, items) }
end
assert_equal items, import.reload.imported_items             # nothing lost, nothing doubled
```

## 4. Halt and resume

```ruby
perform_enqueued_jobs { ImportJob.perform_later(import) }
run = ImportJob.workflow_runs.for(import).sole
assert_equal "halted", run.status
assert_equal "InsufficientStorageError", run.error_class      # halt_on
# or: assert_equal "tool_approval", run.halt_reason           # halt!

fix_the_world
perform_enqueued_jobs { run.resume! }
assert_equal "completed", run.reload.status
```

## 5. Timers

```ruby
travel_to now do
  perform_enqueued_jobs { License::LifecycleJob.perform_later(license) }   # reaches :remind, parks
  run = License::LifecycleJob.workflow_runs.for(license).sole
  assert_equal "waiting", run.status
  assert_equal license.expires_at - 2.weeks, run.wake_at
  assert_no_enqueued_emails
end

travel_to license.expires_at - 2.weeks do
  perform_enqueued_jobs { ActiveJob::Durable.wake_up_due }                 # the clock, then :remind runs, parks at :expire
  assert_enqueued_email_with LicenseMailer, :expiring_two_weeks, args: [license]
end
```

Test what the step did, then where the run parked next. Test re-arming: move the date, tick
the clock, assert the reminder did not go out. Test `wake_up` with no name: the step runs now.
Wake with `ActiveJob::Durable.wake_up_due` inside `travel_to`; do not assert how many runs it
woke or call the wake job directly.

## 6. Signals

```ruby
perform_enqueued_jobs { BulkImportJob.perform_later(import) }   # parks at :confirmation
run = import.job_run
assert_equal "awaiting", run.status

perform_enqueued_jobs { run.wake_up(:confirmation, true) }
assert_equal "applied", import.reload.state
```

Also test the deadline: `travel_to` past it, `perform_enqueued_jobs { ActiveJob::Durable.wake_up_due }`,
the import is destroyed. And the early signal: `wake_up` before the first execution, then the run
completes without parking. Assert on the model; the run's `status` is the second assertion.

## 7. Uniqueness

```ruby
assert ImportJob.perform_later(import)
assert_equal false, ImportJob.perform_later(import)          # :skip
assert_equal 1, Run.count
```

`:reject`: `assert_raises(ActiveJob::Durable::RunAlreadyExists)`. `:replace`: the first run is
`cancelled`, the second is `enqueued`, `Run.count == 2`. After `cancel!` or completion, a new
`perform_later` creates a new run.

## 8. Transactions

```ruby
Account.transaction do
  account.cancel                                   # creates the cancellation, perform_later inside with_lock
  assert_enqueued_jobs 0                           # not yet: enqueue waits for commit
  assert_equal 1, Run.count                        # the row is already there
end
assert_enqueued_jobs 1

Account.transaction do
  account.cancel
  raise ActiveRecord::Rollback
end
assert_equal 0, Run.count
assert_enqueued_jobs 0
```

## 9. Cancel

Cancel a run, then perform: the model is untouched and the run is `cancelled`. Cooperative cancel
of a running step is the gem's feature; do not test it in the app.

## 10. What not to test

Test logic, not the gem. Do not assert on `parked_job`, `pending_signals`, `resumptions`, step
row attempts, cursors, the number of executions, or how many runs the clock woke. Assert on your
models first, then on `status`, `current_step`, `completed_steps`, `state`, `wake_at`,
`halt_reason` and `error_class` when the test is about them.
