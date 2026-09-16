# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Ajdc
  # Installs the tables ActiveJob::Durable writes to:
  #
  #   bin/rails generate ajdc:install
  #
  # Emits both a schema file (for a separate "durable" database, the Solid Queue
  # convention) and a timestamped migration (for a single-database application).
  # Apply one of them, see USAGE.
  class InstallGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration

    def self.source_paths
      [File.expand_path("templates", __dir__), File.expand_path("../../../../db", __dir__)]
    end

    def copy_schema
      copy_file "durable_schema.rb", "db/durable_schema.rb"
    end

    def create_migration_file
      migration_template "create_active_job_durable_tables.rb.tt", File.join(db_migrate_path, "create_active_job_durable_tables.rb")
    end
  end
end
