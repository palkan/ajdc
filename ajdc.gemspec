# frozen_string_literal: true

require_relative "lib/ajdc/version"

Gem::Specification.new do |s|
  s.name = "ajdc"
  s.version = Ajdc::VERSION
  s.authors = ["Vladimir Dementyev"]
  s.email = ["dementiev.vm@gmail.com"]
  s.homepage = "https://github.com/palkan/ajdc"
  s.summary = "Active Job Durable Continuation"
  s.description = "Active Job Durable Continuation"

  s.metadata = {
    "bug_tracker_uri" => "https://github.com/palkan/ajdc/issues",
    "changelog_uri" => "https://github.com/palkan/ajdc/blob/master/CHANGELOG.md",
    "documentation_uri" => "https://github.com/palkan/ajdc",
    "homepage_uri" => "https://github.com/palkan/ajdc",
    "source_code_uri" => "https://github.com/palkan/ajdc",
    "rubygems_mfa_required" => "true",
    "hyperdrive_targets" => "activejob",
    "hyperdrive_artifacts" => "skill"
  }

  s.license = "MIT"

  s.files = Dir.glob("lib/**/*") + Dir.glob("db/**/*") + Dir.glob("skills/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  s.require_paths = ["lib"]
  s.required_ruby_version = ">= 3.3"

  rails_version = ">= 8.1"
  s.add_dependency "activerecord", rails_version
  s.add_dependency "activejob", rails_version
  s.add_dependency "railties", rails_version

  s.add_development_dependency "sqlite3", ">= 2.0"

  s.add_development_dependency "bundler", ">= 2.0"
  s.add_development_dependency "rake", ">= 13.0"
  s.add_development_dependency "minitest", "~> 6.0"
end
