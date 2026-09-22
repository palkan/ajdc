# Uniqueness: one live run per identity

`unique_by` names the `perform` parameters that identify a run and forbids a second live run
for the same identity. The check runs at `perform_later`, inside the caller's transaction; the
unique index on `[job_class, active_key]` settles concurrent enqueues. Terminal runs
(`completed`, `discarded`, `cancelled`) free the identity.

## `:skip` (default): the second start is a no-op

For a sweep that starts runs, a button clicked twice, a webhook delivered twice.

```ruby
class License::LifecycleJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :license

  def perform(license) = # ...
end

# a daily starter for licenses expiring within 30 days; running it twice starts nothing new
License.expiring_within(30.days).find_each { License::LifecycleJob.perform_later(it) }
License::LifecycleJob.perform_later(license)   # => false while a run is live
```

## `:replace`: the new start cancels the live run

For a reschedule or a renewal, when the date the run waits for has moved.

```ruby
class AppointmentReminderJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :appointment, on_conflict: :replace

  def perform(appointment)
    step :remind, wait_until: appointment.start_at - 30.minutes do
      AppointmentNotification.with(appointment:).deliver_later(appointment.patient)
    end
  end
end

# PatientAppointment: after_create_commit, and after_update_commit when start_at changed:
#   AppointmentReminderJob.perform_later(self)      # the old run is cancelled, a new one parks
```

## `:reject`: the second start is an error

For money and anything where a duplicate must be seen, not swallowed.

```ruby
class PayoutJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :payout, on_conflict: :reject

  def perform(payout, wallet_id, amount) = # ...
end

PayoutJob.perform_later(payout, wallet_id, amount)
PayoutJob.perform_later(payout, wallet_id, amount)   # raises ActiveJob::Durable::RunAlreadyExists; error.run is the live one
```

`unique_by :payout` also lets a webhook find the run with the payout alone:
`payout.job_run.wake_up(:payment, ...)`.

## Identity inside an argument

When the identity is not a `perform` parameter but a value inside one, name it with a block.
A Stripe webhook payload:

```ruby
class Payment::ChargeImportJob < ApplicationJob
  include ActiveJob::Durable

  unique_by { |payload| payload.dig("data", "object", "id") }   # the charge id; :skip

  def perform(payload)
    step :import do
      Payment::StripeChargeImport.call(payload.dig("data", "object"))
    end
  end
end
```

Keep an idempotency guard inside the step when a duplicate may arrive after the run completed:
uniqueness covers live and attention runs only.
