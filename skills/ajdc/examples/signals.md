# Signals

## Before: a state column, a controller action, a worker with no memory, a vacuum

```ruby
class BulkImport < ApplicationRecord
  CONFIRM_PERIOD = 10.minutes
  enum :state, { unconfirmed: 0, scheduled: 1, in_progress: 2, finished: 3 }, prefix: true
  scope :confirmation_missed, -> { state_unconfirmed.where(created_at: ..CONFIRM_PERIOD.ago) }
end

class Settings::ImportsController
  def confirm
    @bulk_import.update!(state: :scheduled)
    BulkImportWorker.perform_async(@bulk_import.id)
    redirect_to settings_imports_path
  end
end

class Vacuum::ImportsVacuum                                     # daily
  def perform = BulkImport.confirmation_missed.in_batches.delete_all
end
```

## After

```ruby
class BulkImportJob < ApplicationJob
  include ActiveJob::Durable

  attribute :confirmed, :boolean, default: false

  def perform(import)
    await :confirmation, wait: 10.minutes
    return import.destroy! unless confirmed
    step :apply do
      BulkImportService.new.call(import)
    end
  end

  def confirmation(signal) = self.confirmed = signal.presence
end

# Form::Import#save, after the rows are inserted:  BulkImportJob.perform_later(bulk_import)
# Settings::ImportsController#confirm:             @bulk_import.job_run.wake_up(:confirmation, true)
# BulkImport#job_run:                              BulkImportJob.workflow_runs.for(self).live.sole
```

The vacuum is gone because the deadline fires on the clock's next tick. Ops:
`BulkImportJob.workflow_runs.awaiting.count`, `.at_step(:apply).stuck_for(1.hour)`, `.attention`.

## Before: a payout with two entry points tied by a token

```ruby
class WithdrawFundsJob < ApplicationJob
  def perform(payout, wallet_id, amount) = Wallet::Withdraw.(wallet_id:, amount:, payout:)
end

class PaymentWebhooksController
  def create
    ProcessPaymentJob.perform_later(*params.slice(:token, :status, :amount))
    head :ok
  end
end

class ProcessPaymentJob < ApplicationJob
  def perform(token, status, amount)
    payout = Payout.find_by!(token:)
    Ledger.credit!(payout.account, amount)
    payout.completed!
  end
end
```

## After

```ruby
class PayoutJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :payout, on_conflict: :reject
  attribute :payment

  def perform(payout, wallet_id, amount)
    @payout = payout
    step :withdraw do
      Wallet::Withdraw.(wallet_id:, amount:, payout:)
    end
    await :payment, wait: 3.days
    step :credit
  end

  def payment(signal)
    halt!(:payment_overdue) if signal.nil?
    halt!(:payment_failed)  if signal["status"] == "failed"
    self.payment = signal
  end

  def credit
    Ledger.credit!(@payout.account, payment["amount"])
    @payout.completed!
  end
end

class PaymentWebhooksController
  def create
    payout = Payout.find_by!(token: params[:token])
    payout.job_run.wake_up(:payment, params.slice(:status, :amount).to_h)
    head :ok
  end
end
```

A halted run sits in `PayoutJob.workflow_runs.attention` with a reason; nothing is silently
stuck. `unique_by :payout` is what lets the webhook find the run with the payout alone.

## Human review with a deadline

```ruby
class CardGenerationJob < ApplicationJob
  include ActiveJob::Durable

  attribute :verdict, :string

  def perform(card)
    @card = card
    step :prepare,  isolated: true
    step :moderate, isolated: true
    await :review, wait: 1.hour if verdict == "unsure"
    step :generate, isolated: true unless verdict == "rejected"
  end

  def moderate       = self.verdict = Moderator.verdict(@card)
  def review(value)  = self.verdict = value || "rejected"          # nil at the deadline
end

# Admin action "Approve": card.generation_run.wake_up(:review, "approved")
# Review queue:           CardGenerationJob.workflow_runs.awaiting.at_step(:review)
```
