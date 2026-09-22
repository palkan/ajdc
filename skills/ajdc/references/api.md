# AJ/DC API reference (differences that matter)

## 1. Setup

```ruby
gem "ajdc"
bin/rails generate ajdc:install                     # migration for the two tables in the primary database
bin/rails generate ajdc:install --database=durable  # or in a separate database, plus the initializer
```

Which database, and why it matters: `installation.md` §2.

```yaml
# config/recurring.yml (Solid Queue) or the app's scheduler
durable_wake:
  class: ActiveJob::Durable::WakeJob
  schedule: every minute
```

`include ActiveJob::Durable` in the job. It includes `Continuable`; `step`, `start:`,
`isolated:`, `step.cursor`, `step.set!`, `step.advance!`, `step.checkpoint!`, `attribute`,
`retry_on`, `discard_on` are unchanged. The payload carries only the run id; progress and
attributes live on the run row.

## 2. Identity: `identified_by` versus `unique_by` versus `set(workflow_key:)`

| Macro | Answers | Column | Effect on enqueue |
|---|---|---|---|
| none | "what is this run about?" | `key` = all arguments, positional in order then keywords `name=value` | none |
| `identified_by :card` | same, narrowed to the named `perform` parameters | `key` from those parameters only | none |
| `identified_by { \|card, **kw\| [card, kw.fetch(:format, "csv")] }` | same, computed | `key` from the block's return | none |
| `unique_by :card` | "may two live runs exist for this?" | `active_key` while live or attention; `NULL` when terminal | `on_conflict` applies |
| `unique_by { \|payload\| payload.dig("data", "object", "id") }` | same, computed; also sets `key` when `identified_by` is absent | `active_key` (and `key`) from the block's return | `on_conflict` applies |
| `set(workflow_key: "x")` | one run's key, verbatim | `key` | none |

- `identified_by` only names the run; use it so `workflow_runs.for(card)` finds the run
  whatever the other arguments were.
- `unique_by` takes the same forms as `identified_by`: names or a block. Alone, it also names
  the run, so one declaration covers both columns. Declare both only when identity and
  uniqueness must differ; then the two derive independently.
- An unknown parameter name raises `ArgumentError` at declaration or first enqueue.
- Identity inside a hash argument (a webhook payload): use the block form.

`on_conflict`, checked at `perform_later` inside the caller's transaction, decided for
concurrent enqueues by the unique index on `[job_class, active_key]`:

| Value | Behaviour | Use for |
|---|---|---|
| `:skip` (default) | enqueues nothing, `perform_later` returns `false` | sweeps that start runs, double clicks, webhook retries |
| `:reject` | raises `ActiveJob::Durable::RunAlreadyExists` (`error.run`) | payouts, anything with money |
| `:replace` | `cancel!` the live run, start a new one, one transaction | reschedules, renewals, "the date moved" |

## 3. Timers: `wait:` versus `wait_until:`

```ruby
step :remind, wait_until: license.expires_at - 2.weeks   # at a time
step :revoke, wait: 2.weeks                              # after the previous step completed
step :lazy,   wait_until: -> { expensive_query.date }    # callable: evaluated only when the step is reached
```

| | `wait:` | `wait_until:` |
|---|---|---|
| Takes | a Duration (or callable) | a Time (or callable) |
| Anchored | once, at the previous step's completion (run start for a first step) | re-evaluated at every pass, including wake |
| Target moves | does not move | re-arms by itself: `license.expires_at` changed, the run parks again |
| Target in the past | runs at once | runs at once |

A plain expression on the `step` line is evaluated on every pass, because `perform` re-runs on
each resume and skips completed steps; use a callable only when the expression is expensive.

Parked run: status `waiting`, `wake_at` set, nothing in the queue. `WakeJob` wakes due runs;
precision is its interval. `run.wake_up` (no arguments) ends the wait now. `run.cancel!` stops
the clock for that run.

## 4. Signals: `await` and `wake_up`

```ruby
def perform(import)
  await :confirmation, wait: 10.minutes        # deadline uses the timer keywords
  return import.destroy! unless confirmed
  step :apply
end

def confirmation(signal) = self.confirmed = signal.presence   # nil at the deadline

# elsewhere
import.job_run.wake_up(:confirmation, true)
```

- `await :name` is a step with an empty body; the method `name(value)` (or a block
  `await(:name) { |value| ... }`) runs on wake with the value. `nil` means the deadline passed.
- `wake_up(name, value)`: any JSON value. Sent before the `await` line is reached, it waits in
  `pending_signals` and is consumed without parking. A second signal for the same name
  overwrites. A run that is not live raises `ActiveJob::Durable::NotLive`.
- The value is kept on the step row, so a crash in a later step replays the same argument.
- `halt!` inside the handler leaves the await incomplete; `resume!` awaits again with a fresh
  deadline.
- `wake_up` with no name wakes whatever is parked: a timer ends now, an await receives `nil`.
- Names must be unique per run; no `await` in a loop with a fixed name.

## 5. Stopping: `halt_on`, `halt!`, `resume!`, `cancel!`

| Call | From | Status after | Then |
|---|---|---|---|
| `retry_on E` | class | `enqueued` (retry wait) | automatic |
| `discard_on E` | class | `discarded` | nothing; terminal |
| `halt_on E` | class | `halted`, `error_class`, `error_message`, step row `halted` with cursor | `run.resume!` |
| `halt!(reason)` | inside a step | `halted`, `halt_reason` | `run.resume!` |
| uncaught error | | `failed`, error columns | `run.resume!` or a backend retry |
| `run.cancel!` | outside | `cancelled`, `active_key` cleared | nothing; terminal |
| `return` from `perform` | inside | `completed` | nothing |

Declared handlers win over resume: an error with a `discard_on`/`retry_on`/`halt_on` goes to
that handler; only undeclared errors are resumed by Continuation. No `resume_job` override.

`resume!` re-enqueues at the halted or failed step, from its cursor, as a new attempt; earlier
attempts keep their errors; manual resumes do not count toward `max_resumptions`. `cancel!` of a
running job takes effect at its next checkpoint or step boundary.

## 6. Statuses

| Group | Statuses | Scope |
|---|---|---|
| live | `enqueued` (in the queue), `running` (in a worker), `waiting` (timer), `awaiting` (signal) | `live` |
| attention | `failed`, `halted` | `attention`; resumable |
| terminal | `completed`, `discarded`, `cancelled` | `terminal` |

`enqueued` is written at every re-enqueue (isolated step, graceful stop, `retry_on`). An
`enqueued` run with `started_at` null never ran. `stuck_for(1.hour)`: `running` with a stale
heartbeat, or `enqueued`/`waiting`/`awaiting` with a stale transition.

## 7. Reading runs

```ruby
MyJob.workflow_runs                                   # this class, newest first
MyJob.workflow_runs.for(card)                         # the key perform_later(card) derives
MyJob.workflow_runs.for(workflow_key: "cards/42")
MyJob.workflow_runs.for(card).live.first              # or .sole under unique_by
MyJob.workflow_runs.awaiting.at_step(:review)         # the review queue
MyJob.workflow_runs.halted / .failed / .attention
MyJob.workflow_runs.stuck_for(1.hour)
run.status, run.current_step, run.completed_steps, run.state, run.wake_at, run.halt_reason
run.steps                                             # one row per attempt: name, attempt, status, cursor, timings, error
```

Give the model a method for its run instead of a class-level helper:

```ruby
def job_run = ImportJob.workflow_runs.for(self).live.sole
```

## 8. Callbacks

`before_step`, `after_step`, `around_step`: `ActiveSupport::Callbacks`, the `before_perform`
shape. They run for steps that execute, not for skipped ones; `after_step` only on completion.
`current_step` is the running `Step`. `throw :abort` in `before_step` skips the body and marks
the step completed.
