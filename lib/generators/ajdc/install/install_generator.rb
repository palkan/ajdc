# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Ajdc
  # Creates the migration for the tables ActiveJob::Durable writes to:
  #
  #   bin/rails generate ajdc:install                      # the primary database
  #   bin/rails generate ajdc:install --database=durable   # a separate database, plus the initializer
  #
  # With `--database`, the migration lands in that database's `migrations_paths`
  # (as `rails generate migration --database` does) and an initializer points
  # `ActiveJob::Durable` at it. The database itself is declared in
  # config/database.yml by the app.
  class InstallGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    class_option :database, type: :string, aliases: %i[--db],
      desc: "The database for the tables. By default, the current environment's primary database is used."

    def create_migration_file
      migration_template "create_active_job_durable_tables.rb.tt", File.join(db_migrate_path, "create_active_job_durable_tables.rb")
    end

    def create_initializer
      return unless options[:database]

      template "initializer.rb.tt", "config/initializers/active_job_durable.rb"
    end

    def show_database_instructions
      return unless options[:database]
      return if database_configured?

      say <<~TEXT

        Add the database to config/database.yml, then run bin/rails db:prepare:

          #{options[:database]}:
            <<: *default
            database: storage/#{options[:database]}.sqlite3   # or your adapter's settings
            migrations_paths: db/#{options[:database]}_migrate

      TEXT
    end

    private

    # Rails resolves `--database` through config/database.yml; a database that is
    # not declared yet gets the conventional path, which the instructions name.
    def db_migrate_path
      return super if options[:database].nil? || database_configured?

      "db/#{options[:database]}_migrate"
    end

    def database_configured?
      ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: options[:database]).present?
    rescue
      false
    end
  end
end
