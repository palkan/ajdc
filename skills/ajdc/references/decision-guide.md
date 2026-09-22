# Decision guide: workflow, sweep, or hybrid

## 1. The three ways to do "later"

| | Cron sweep | Parked run per entity | Hybrid |
|---|---|---|---|
| Shape | a recurring job scans a table for due rows | one `Durable` run per entity, `wait_until:` | a recurring job starts runs for entities due within a window |
| Where the schedule lives | cron YAML + a scope | the job's `perform`, top to bottom | both, the window in cron, the steps in the job |
| Idempotency | by hand: claim columns, bucket arithmetic | by `unique_by` and completed steps | `unique_by ..., on_conflict: :skip` makes the sweep idempotent |
| Reschedule | data-driven, free (the next scan re-derives) | `perform_later` again with `:replace`, or the moved `wait_until:` re-arms on wake | same as parked |
| "Where is X?" | a query on the entity table | `workflow_runs.for(x)` | same |
| Rows at rest | none | one run row per live entity | one per entity inside the window |
| Precision | the cron interval | the `WakeJob` interval (one minute) | one minute |
| Best when | the rule is a policy over a table, or rows number in the millions | the wait belongs to one entity and has steps before or after it | many entities, far-future dates |

Rules:

- **Park when the wait belongs to one entity and is part of a sequence.** A license lifecycle
  (remind, expire, revoke), an appointment reminder, a 30-day grace period, a payout waiting for
  a webhook.
- **Sweep when the rule is a policy over a table.** "Delete chats older than 7 days", "post the
  weekly digest", "rebuild the facts nightly". No entity has a position in it.
- **Hybrid when both are true:** thousands of entities with dates years ahead. Start a run only
  for entities due within N days; `unique_by :entity` with the default `:skip` makes the daily
  starter idempotent. Cancel on the entity's terminal event.

A parked run costs one row and nothing in the queue: the run is parked on the row, not in the
adapter, and `WakeJob` wakes due runs. So "too many jobs waiting" is not the parked design's
cost anymore; the cost is rows, and rows are cheap. What still argues for a sweep is the rule's
nature, not volume.

## 2. Replacing a sweep: the checklist

Before you replace a working sweep, confirm each:

1. Each row the sweep touches has an owner entity and a start event (created, cancelled,
   confirmed) where `perform_later` can be called.
2. There is a terminal event where the run should be cancelled (submitted, reactivated, paid).
   Without one, runs accumulate as `waiting` and the sweep was right.
3. The sweep's idempotency tricks (claim columns, `expires_at` buckets, `updated_at` compared
   at wake) exist only because the parked job had no identity. `unique_by` removes them; if they
   exist for another reason, keep them.
4. The precision of one minute is enough. It is for e-mail, Slack, billing; it is not for
   sub-minute SLAs.
5. If the sweep also heals data (re-imports charges the webhook missed), keep the sweep as the
   safety net and add the run for observability; both can coexist.

If 1 or 2 fails, keep the sweep. If you keep a sweep and want observability, make the sweep
itself a `Durable` job with a cursor; the run row shows progress and the last error.

## 3. Signals: `await` versus a state column plus a controller

Today's shape: a state column (`unconfirmed → scheduled → done`), a controller action that flips
it and enqueues the second half, a vacuum for the ones nobody confirmed. Problems: the second
half has no memory of the first, the deadline is enforced by a daily job, two entry points can
race.

`await` keeps one job with the wait in the middle. Use it when:

- the flow has steps before and after the wait (parse then apply; withdraw then credit);
- the wait has a deadline (`wait: 10.minutes`, `wait: 3.days`) or must be observable
  (`workflow_runs.awaiting.at_step(:review)` is the review queue);
- the signal carries a value the later steps need (a verdict, a payment amount).

Keep the controller-flips-a-state shape when the "signal" is the only thing that ever happens
(no second half), or when the decision must survive without any job (an audit record). Both can
coexist: write the decision to the model and `wake_up` the run.

### Repeated decisions

`await` is a step, and step names are unique per run: an `await :decision` inside a loop is
completed after the first pass and skipped on every later one. Three cases:

| The decision | Shape |
|---|---|
| needs no value, only a go (the choice is already a row somewhere) | `halt!(:reason)` inside the loop; `resume!` from the outside. A halt is not a step; it can happen any number of times. |
| carries a value, from a set known when `perform` runs | one `await` per name, e.g. per approver |
| carries a value, an unknown number of times | write the value to a model, then `halt!`/`resume!`; the run reads the model when it continues |

A known set, N approvers snapshotted at submission:

```ruby
def perform(time_off)
  @time_off = time_off
  step :notify_approvers
  time_off.approvals.each do |approval|
    await :"decision_#{approval.approver_id}", wait: 3.business_days
  end
  step :finalize
end

def method_missing(name, decision = nil)
  return super unless name.start_with?("decision_")
  halt!(:approver_silent) if decision.nil?                                # the deadline passed
  @time_off.approvals.find_by!(approver_id: name.to_s.delete_prefix("decision_")).decide!(decision)
end

# controller: time_off.approval_run.wake_up(:"decision_#{current_member.id}", params[:decision])
```

The awaits run in order; a rejection can end the run early from its handler. Approvers are
notified together in the first step, so waiting in order costs nothing visible.

## 4. `halt!` versus `await` versus `retry_on`

| Situation | Use |
|---|---|
| a transient error (network, lock) | `retry_on` |
| an error nothing can fix (corrupt file) | `discard_on` |
| an error a person fixes, then the run continues (out of storage, wrong config) | `halt_on Error`, then `run.resume!` |
| a decision that needs no data, only a go (tool approval already recorded elsewhere) | `halt!(:reason)`, then `run.resume!` |
| a decision that carries data (approve/reject, a webhook payload) | `await :name`, then `run.wake_up(:name, value)` |
| a fixed wait | `step :x, wait: 2.weeks` |
| a wait until a date on the record | `step :x, wait_until: record.date` |

## 5. `isolated: true`

Use `isolated: true` on steps that call slow external services (LLM, third-party API) so each
step runs as its own job execution and no single run holds a worker for minutes. Not needed for
steps that touch only the database. Isolation costs one re-enqueue per step.

## 6. When not to use AJ/DC

- Fan-out and fan-in (one step that spawns N jobs and waits for all). Use Solid Queue batches
  (1.7+), GoodJob batches, or Sidekiq Pro; AJ/DC has no batch primitive yet. A `Durable` run may
  start the batch and `await` the batch's `on_finish` job as a signal.
- Replay-based determinism or exactly-once semantics. Steps are at-least-once; a completed step
  is skipped on resume. Make step bodies idempotent (upserts, `find_or_create_by`, guards on a
  fact column).
- Sub-minute timers. The clock ticks with the scheduler.
