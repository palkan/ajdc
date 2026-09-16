# frozen_string_literal: true

begin
  require "debug" unless ENV["CI"]
rescue LoadError
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
ENV["RAILS_ENV"] = "test"
ENV["TARGET_DB"] ||= "sqlite"

begin
  require_relative "../test/dummy/config/environment"
  ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
rescue => e
  $stdout.puts "Failed to load the app: #{e.message}\n#{e.backtrace.take(5).join("\n")}"
  exit(1)
end

def rails_version_is(range, &)
  if range.cover?(ActiveJob::VERSION::STRING)
    block_given? ? yield : true
  else
    false
  end
end

# Create the primary test database when it is not SQLite (which is created on connect),
# then (re)load the gem's schema into it, so the suite runs from a clean checkout.
ActiveRecord::Tasks::DatabaseTasks.create_current("test", "primary") unless ENV["TARGET_DB"] == "sqlite"
ActiveRecord::Schema.verbose = false
ActiveJob::Durable::Record.connection_pool.with_connection do |connection|
  connection.drop_table :active_job_durable_steps, if_exists: true
  connection.drop_table :active_job_durable_runs, if_exists: true
end
load File.expand_path("../db/durable_schema.rb", __dir__)
load File.expand_path("dummy/db/schema.rb", __dir__)

Dir["#{__dir__}/support/**/*.rb"].sort.each { |f| require f }

require "minitest/autorun"

class ActiveSupport::TestCase
  def before_setup
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
    ActiveJob::Base.queue_adapter.perform_enqueued_at_jobs = true
  end
end
