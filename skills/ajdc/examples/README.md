# Examples: before and after

Each file shows a real shape found in Rails apps and its `ActiveJob::Durable` version. Names
are generic. Read the one that matches the shape you found (see SKILL.md §2).

- `pipeline.md`: a chain of jobs with a status enum, or a state machine with a self-re-enqueuing job
- `timers.md`: cron sweeps and `set(wait_until:)` with invalidation
- `signals.md`: a state column plus a controller action; a webhook that continues a flow
- `halting.md`: an error a person fixes; rescue-inside-the-step shapes
- `uniqueness.md`: one live run per identity; `:skip`, `:replace`, `:reject`; identity inside an argument
- `agent-loop.md`: an LLM loop with a tool approval
