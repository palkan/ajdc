# Transactions and AJ/DC

The run row lives in the app's database (or a separate `durable` database via
`ActiveJob::Durable.connects_to`). These rules follow from that.

## 1. `perform_later` inside a transaction

- The run row is created in the caller's transaction. The queue message is enqueued after all
  transactions commit (Rails `enqueue_after_transaction_commit`). A rollback removes the row and
  sends nothing.
- So: call `perform_later` inside the same transaction that creates or changes the entity
  (`with_lock`, `transaction do ... end`). The run and the entity commit or roll back together.
  This is the outbox pattern without an outbox table.
- `unique_by` is checked in that transaction too. Concurrent enqueues are decided by the unique
  index on `[job_class, active_key]`; the loser gets `:skip`, `:reject` or `:replace` semantics.
- If the run row is in a separate database, the two databases do not share a transaction. Then
  a rollback of the entity leaves an `enqueued` run whose job will find no entity; guard the
  first step, or keep runs in the primary database when transactional creation matters.

## 2. `wake_up`, `resume!`, `cancel!` inside a transaction

- Each is one status-guarded `UPDATE` on the run row. It joins the caller's transaction like any
  other write.
- The re-enqueue of the parked job happens after all transactions commit. Inside a rolled-back
  transaction nothing is enqueued and the status update is undone.
- A guarded update that matches zero rows raises (`NotLive`, `NotResumable`, `NotCancellable`,
  `NotWaiting`). Re-find the run right before the call; do not use a run loaded minutes earlier.
- `on_conflict: :replace` is `cancel!` of the live run plus the new run's row in one
  transaction; a wake of the cancelled run is a no-op.

## 3. Writes the gem makes while the job runs

- Every step boundary and every checkpoint (`step.set!`, `step.advance!`, `step.checkpoint!`) is
  a committed write to the run and step rows, outside your step's transaction.
- Do not wrap a whole step body in one long transaction and checkpoint inside it: the
  checkpoint commits on its own connection state, but your work does not, and a crash leaves the
  cursor ahead of the data. Commit per item, then checkpoint.
- Every run-row write is guarded on `status = 'running'`. A `cancel!` from elsewhere makes the
  next checkpoint raise `ActiveJob::Durable::Cancelled`; the step body stops there.
- Attribute changes (`self.verdict = ...`) are written with the next checkpoint or step
  boundary, not immediately.

## 4. Step bodies

- At-least-once per step. Make step bodies idempotent: `find_or_create_by`, `upsert_all`, a
  guard on a fact column (`return if payout.completed?`).
- A step that both writes the entity and calls an external service: write the external call's
  result to the entity in the same step, and check the entity first on re-run.
- Isolated steps run in separate executions; a shared instance variable does not survive. Set
  `@record = record` at the top of `perform`, which re-runs on every execution, or use
  `attribute`.

## 5. Locks

- `with_lock` on the entity plus `perform_later` inside it is fine and recommended for
  start/cancel pairs (cancel an account: create the cancellation, start the run; reactivate:
  destroy it, cancel the run).
- Do not hold an entity lock across a step boundary; the step boundary is a separate write and
  the job may be re-enqueued between steps.
- SQLite: one writer. Checkpoints are short writes; keep step bodies' transactions short too, or
  `limits_concurrency` heavy writers as the app already does.

## 6. Tests

Transactional tests wrap each test in a non-joinable transaction, so an app-level
`transaction do ... end` still commits its savepoint and `after_all_transactions_commit`
fires; `perform_later` inside `with_lock` enqueues in tests as in production. Verify with
`assert_enqueued_jobs`. See `testing.md`.
