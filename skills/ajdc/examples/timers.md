# Timers

## Before: three cron entries and three sweeps

```yaml
license_expiration_reminder: { class: License::ReminderJob, args: [60], schedule: "26 * * * *" }
license_expiration:          { class: License::ExpirationJob,   schedule: "13 */2 * * *" }
license_revoke:              { class: License::RevokeAccessJob, schedule: "51 */12 * * *" }
```

```ruby
class License::ReminderJob < ApplicationJob
  def perform(interval, now = Time.current)
    future = now + 2.weeks
    shift = future.to_i % interval                                   # bucket so each license gets one reminder
    License.where(expires_at: (future - shift)...(future + interval - shift), status: [:trial, :active])
           .find_each { LicenseDelivery.with(license: it).license_expiring_two_weeks.deliver_later }
  end
end
```

## After: one run per license

```ruby
class License::LifecycleJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :license, on_conflict: :replace

  def perform(license)
    @license = license
    step :remind, wait_until: license.expires_at - 2.weeks
    step :expire, wait_until: license.expires_at
    step :revoke, wait: 2.weeks
  end

  def remind = LicenseDelivery.with(license: @license).license_expiring_two_weeks.deliver_later
  def expire = @license.expired!.then { LicenseDelivery.with(license: @license).license_expired.deliver_later }
  def revoke = @license.revoke_later.then { LicenseDelivery.with(license: @license).access_revoked.deliver_later }
end

# License: after_create_commit, and after renewal:  License::LifecycleJob.perform_later(self)
```

Renewal restarts the lifecycle with `:replace`, because `remind` is already completed and the
new term needs its own reminder. A moved `expires_at` while waiting re-arms by itself.

## Before: a parked job with hand-made invalidation, then a retreat to a sweep

```ruby
class AppointmentNotificationJob < ApplicationJob
  def self.schedule(appointment)
    set(wait_until: appointment.start_at - 30.minutes).perform_later(appointment.id, appointment.updated_at)
  end

  def perform(appointment_id, updated_at)
    appointment = PatientAppointment.lock.find(appointment_id)
    return unless appointment.updated_at.to_i == updated_at.to_i     # rescheduled meanwhile? drop
    return if appointment.notification_sent_at                       # claim column
    appointment.update!(notification_sent_at: Time.zone.now)
    AppointmentNotification.with(appointment:).deliver_later(appointment.patient)
  end
end
```

## After

```ruby
class AppointmentReminderJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :appointment, on_conflict: :replace

  def perform(appointment)
    step :remind, wait_until: appointment.start_at - 30.minutes do
      next if appointment.hide_from_patient?
      AppointmentNotification.with(appointment:).deliver_later(appointment.patient)
    end
  end
end

# PatientAppointment: after_create_commit, and after_update_commit when start_at changed:
#   AppointmentReminderJob.perform_later(self)
```

No claim column, no `updated_at` argument, no sweep. A parked run has an identity.

## Before: a grace period as a scope and a sweep

```ruby
class Account::IncinerateDueJob < ApplicationJob
  include ActiveJob::Continuable
  def perform
    step :incineration do |step|
      Account.due_for_incineration.find_each { it.incinerate; step.checkpoint! }   # cancellation older than 30 days
    end
  end
end
```

## After: the model starts and cancels the run, inside its lock

```ruby
module Account::Cancellable
  def cancel
    with_lock do
      next unless cancellable? && active?
      create_cancellation!(initiated_by: Current.user)
      Account::IncinerationJob.perform_later(self)                     # row now, message after commit
    end
  end

  def reactivate
    with_lock do
      next unless cancelled?
      cancellation.destroy
      Account::IncinerationJob.workflow_runs.for(self).live.sole.cancel!
    end
  end
end

class Account::IncinerationJob < ApplicationJob
  include ActiveJob::Durable

  unique_by :account

  def perform(account)
    step :incinerate, wait: 30.days do
      account.incinerate
    end
  end
end
```

The sweep was a fine design; this version buys one row per pending deletion that anyone can
query and a reactivation that cannot race the sweep.
