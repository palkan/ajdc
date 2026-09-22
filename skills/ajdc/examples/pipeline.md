# Pipeline

## Before: a chain of jobs and a status enum

```ruby
class AnalyzeCardJob < ApplicationJob
  def perform(card)
    card.analyzing!
    if NSFWDetector.check(card.image) then card.analyzed!; GenerateCardJob.perform_later(card)
    else card.fail!("NSFW check failed") end
  end
end

class GenerateCardJob < ApplicationJob
  def perform(card)
    card.generating!
    card.attach_rendition(CardPainter.paint(card))
    card.generated!
  end
end
```

## Before: a state machine and a job that re-enqueues itself

```ruby
class Cable::DiagnosticJob < ApplicationJob
  def perform(diagnostic)
    level = diagnostic.check!                       # runs the check for the current state
    return diagnostic.update!(state: :halted, halted_reason: level) unless level == :success
    diagnostic.next!
    self.class.perform_later(diagnostic) unless diagnostic.completed?
  end
end
```

## After

```ruby
class Cable::DiagnosticJob < ApplicationJob
  include ActiveJob::Durable

  attribute :metadata, default: {}
  attribute :error_msg, :string

  after_step :broadcast_update

  def perform(cable)
    @cable = cable
    step :provider_status,  isolated: true
    step :websocket_status, isolated: true
    step :admin_api_status, isolated: true
  end

  private
    def provider_status  = check(:provider_status)
    def websocket_status = check(:websocket_status)
    def admin_api_status = check(:admin_api_status)

    def check(name)
      result = public_send(:"check_#{name}")
      self.error_msg = result.reason
      halt!(result.level) unless result.level == :success
      metadata[name] = result.data
    end

    def broadcast_update = @cable.broadcast_replace(partial: "cables/diagnostic", locals: { step: current_step.name })
end
```

What moved: the transitions table is the three `step` lines; "one check per job run" is
`isolated: true`; the broadcast is one `after_step`; the halt has a reason and is resumable; the
UI reads the run (`status`, `current_step`, `state`) instead of a cached record. The card's own
facts (`generated`, `failed`) stay on the card.
