# frozen_string_literal: true

require_relative 'lib/jetstream_bridge/version'

Gem::Specification.new do |spec|
  spec.name                  = 'jetstream_bridge'
  spec.version               = JetstreamBridge::VERSION
  spec.authors               = ['Mike Attara']
  spec.email                 = ['mpyebattara@gmail.com']

  spec.summary     = 'Reliable realtime bridge over NATS JetStream for Rails/Ruby apps'
  spec.description = <<~DESC.strip
    Publisher/Consumer utilities for NATS JetStream with environment-scoped subjects,
    overlap guards, DLQ routing, retries/backoff, and optional Inbox/Outbox patterns.
    Includes topology setup helpers for production-safe operation.
  DESC

  spec.license  = 'MIT'
  spec.homepage = 'https://github.com/attaradev/jetstream_bridge'

  # Runtime environment
  spec.required_ruby_version     = '>= 2.7.0'
  spec.required_rubygems_version = '>= 3.3.0'

  # Rich metadata
  spec.metadata = {
    'homepage_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'source_code_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'changelog_uri' => 'https://github.com/attaradev/jetstream_bridge/blob/main/CHANGELOG.md',
    'documentation_uri' => 'https://github.com/attaradev/jetstream_bridge#readme',
    'bug_tracker_uri' => 'https://github.com/attaradev/jetstream_bridge/issues',
    'github_repo' => 'ssh://github.com/attaradev/jetstream_bridge',
    'rubygems_mfa_required' => 'true'
  }

  # Safer file list
  spec.files = Dir.glob('{lib,README*,CHANGELOG*,LICENSE*}/**/*', File::FNM_DOTMATCH)
                  .select { |f| File.file?(f) }
                  .reject { |f| f.start_with?('spec/', '.') }

  spec.require_paths = ['lib']

  # ---- Runtime dependencies ----
  spec.add_dependency 'activerecord',  '>= 6.0'
  spec.add_dependency 'activesupport', '>= 6.0'
  spec.add_dependency 'nats-pure',     '~> 2.4'
  spec.add_dependency 'oj', '>= 3.16'
end
