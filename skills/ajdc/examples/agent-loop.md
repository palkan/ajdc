# Agent loop with a tool approval

## Before (ruby_llm durable-agents guide): one loop step, a finished job on approval

```ruby
class AgentRunJob < ApplicationJob
  include ActiveJob::Continuable

  def perform(chat_id)
    step :agent_loop do |job_step|
      chat = Chat.find(chat_id)
      until chat.complete?
        chat.step
        job_step.checkpoint!
      end
    end
  end
end

class ApprovalsController < ApplicationController
  def create
    chat = Chat.find(params[:chat_id])
    params[:approved] == "true" ? chat.approve(params[:tool_call_id]) : chat.deny(params[:tool_call_id])
    CompleteJob.perform_later(chat.id)
  end
end
```

## After

```ruby
class AgentRunJob < ApplicationJob
  include ActiveJob::Durable

  def perform(chat)
    step :run do |step|
      until chat.complete?
        chat.step
        halt!(:tool_approval) if chat.awaiting_approval?
        step.checkpoint!
      end
    end
  end
end

class ApprovalsController < ApplicationController
  def create
    chat = Chat.find(params[:chat_id])
    params[:approved] == "true" ? chat.approve(params[:tool_call_id]) : chat.deny(params[:tool_call_id])
    chat.agent_run.resume!
  end
end
```

`halt!`, not `await`: the pending tool call is already a row in ruby_llm's tables, so the run
needs a wake, not a payload. `resume!` re-enters the loop step; `chat.step` runs the approved
tool and skips the ones with results. Halted runs: `AgentRunJob.workflow_runs.halted`.
