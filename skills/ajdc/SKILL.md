---
name: ajdc
description: Design, implement, refactor and test durable workflows on Active Job with AJ/DC (`ActiveJob::Durable`). Use when a feature is a multi-step background process, a "do this later" timer (cron sweep, `set(wait_until:)`, a `*_sent_at` claim column), an approval or webhook wait (a state column plus a controller action that re-enqueues), a job that re-enqueues itself, a status enum that tracks a job's position, or a job that must survive a crash and be resumable. Also use when the user asks whether to use a workflow at all.
---

# AJ/DC: durable workflows on Active Job

AJ/DC makes an `ActiveJob::Continuable` job durable: the run and its steps are rows in the
database, so progress survives a crash (not only a graceful stop), a run can wait for a time or
for a signal without holding a worker or a queue slot, and every run is identified and queryable.
Same `step` DSL, same job runner, same `perform_later`.

Read `references/api.md` for the full surface. This file is the decision procedure.

## 1. Decide whether a workflow is the right tool

```
Is it background work with more than one step, or a wait?
├── no → a plain job. Stop.
└── yes
    ├── 1. Does the process wait: for a time, or for someone (approval, webhook, reply)?
    ├── 2. Does anyone need to find a run by its subject, see where it is, or
    │      continue it after a failure from where it stopped?
    ├── both no → ActiveJob::Continuable (Rails 8.1) if a loop must survive a deploy;
    │             otherwise a plain job. Stop.
    └── at least one yes → ActiveJob::Durable. Then:
        ├── it waits (1): does the wait belong to one entity, with steps before or after it?
        │   ├── yes → a run per entity: wait:, wait_until:, await
        │   └── no, it is a policy over a table → keep the cron sweep; hybrid for far-future
        │        dates (references/decision-guide.md §1)
        └── someone watches (2): name the identity (identified_by), decide whether a second
            live run is allowed (unique_by), decide what a person fixes (halt_on).
```

Questions 1 and 2 are the only decisive ones. Uniqueness and per-step error rules are choices
made once inside, not reasons to enter.

## 2. Recognize the shape in existing code

Each row answers question 1 or 2 of the tree.

| You see | It is | Durable shape |
|---|---|---|
| Job A enqueues job B enqueues job C, each flips a status | pipeline | one job, `step :a; step :b; step :c` |
| a state machine gem on a record plus a job that re-enqueues itself | pipeline | steps, `isolated: true` where each step must be its own execution |
| `set(wait_until:)` plus an `updated_at` argument compared at wake | timer with hand-made invalidation | `step :x, wait_until:` plus `unique_by ..., on_conflict: :replace` |
| a cron entry that exists only to check a date column | timer as sweep | `step :x, wait_until: record.date` per entity, or keep the sweep (see guide) |
| `*_sent_at` / `*_notified_at` claim columns per reminder | timers as columns | one step per reminder, `wait_until:` |
| a controller action that flips a state and calls `perform_later` | signal | `await :name`, `run.wake_up(:name, value)` from the action |
| a webhook handler that finds a record by token and continues the flow | signal | `await :name, wait:` with a deadline, `unique_by` on the record |
| a class that serializes "the last run" into a settings row | run record | delete it; `MyJob.workflow_runs.first` |

Secondary signals. They confirm that a workflow fits and name a feature to use once inside;
they do not start one:

- a dedupe guard (`Model.exists?(external_id:)`) next to a per-id `limits_concurrency` key:
  `unique_by`, usually `:skip`;
- a `rescue` inside a step body that flips a status column and returns, so a person can retry
  later: `halt_on` for that error class;
- a `retry_on`/`discard_on` list that grows with every new error class: the three verbs,
  `retry_on`, `discard_on`, `halt_on`, and the rest stays as it is.

## 3. Implement

If the gem is not installed yet, follow `references/installation.md` first: it decides between
the primary and a separate database (the transaction property depends on it) and adds the
recurring wake job, without which no timer or deadline fires.

1. Decide where each piece of state lives. Facts about the record (`paid`, `signed`) stay on
   the model. The process position (`analyzing`, `needs_review`, `generating`) moves to the run.
   Never mirror one into the other.
2. `include ActiveJob::Durable` instead of `ActiveJob::Continuable`. Keep `step`, cursors and
   `attribute` as they are. Run the existing tests; nothing should change.
3. Name the identity. Default key = all arguments. Declare `identified_by` when other arguments
   must not split the key, `unique_by` when only one live run per identity may exist. Pick
   `on_conflict`: `:skip` for sweeps and double clicks, `:reject` for money, `:replace` for
   reschedules and renewals. See `references/api.md` §2.
4. Move waits into steps: `wait:` for "N after the previous step", `wait_until:` for "at this
   time"; both take a value or a callable. Check that `ActiveJob::Durable::WakeJob` is scheduled
   (`references/installation.md` §3).
5. Move signals into `await :name, wait: deadline` plus a method `name(value)`; deliver with
   `run.wake_up(:name, value)` from the controller, webhook or console. `nil` means the deadline
   passed. Add a model method that finds the run (`payout.job_run`) instead of a class-level
   helper.
6. Classify errors: `retry_on` (the machine tries again), `discard_on` (give up), `halt_on` (a
   person fixes it, then `run.resume!`). `halt!(reason)` from inside a step is the same stop
   without an exception.
7. Replace `after_transition`/broadcast calls inside steps with `after_step` /
   `before_step` / `around_step`; read `current_step.name` inside the callback.
8. Replace hand-written run records, status enums that track position, and sweeps that only
   check a date. Keep the model facts.
9. Check the transaction story in `references/transactions.md` for every `perform_later`,
   `wake_up`, `cancel!` you add inside a `transaction`/`with_lock` block.
10. Write the tests per `references/testing.md` before the refactor, against the old behaviour,
   then switch.

## 4. Do not

- Do not add a `status` enum to a model to mirror the run. Query `workflow_runs`.
- Do not `await` inside a loop with a fixed name; step names are unique per run, so the second
  pass would skip it. For a repeated decision that needs no value (a tool approval already
  recorded on a model), `halt!` in the loop and `resume!` from the outside. For a known set of
  valued decisions, one `await` per name: `await :"decision_#{approver.id}"`. For an unknown
  number of valued decisions, store the value on a model and use `halt!`; see
  `examples/agent-loop.md` and `references/decision-guide.md` §3.
- Do not `sleep` inside a step; use `wait:` on the next step.
- Do not call `wake_up`, `resume!` or `cancel!` on a run loaded before a long operation; reload
  or re-find it, the guarded update fails on a stale status.
- Do not put `wait:` and `wait_until:` on the same step.
- Do not replace a sweep that is a policy over millions of rows with millions of parked runs
  without reading `references/decision-guide.md` §2.

## 5. Report

When you finish, list: the jobs converted, the columns/classes/cron entries removed, the
`unique_by` strategy chosen and why, the recurring `WakeJob` entry added, and the queries the
UI or ops now use (`workflow_runs.awaiting`, `.halted`, `.stuck_for(...)`).
