# frozen_string_literal: true

require_relative 'lib/jetstream_bridge/version'

Gem::Specification.new do |spec|
  spec.name                  = 'jetstream_bridge'
  spec.version               = JetstreamBridge::VERSION
  spec.authors               = ['Mike Attara']
  spec.email                 = ['mpyebattara@gmail.com']

  # Clear, value-focused copy
  spec.summary     = 'Reliable realtime bridge over NATS JetStream for Rails/Ruby apps'
  spec.description = <<~DESC.strip
    Publisher/Consumer utilities for NATS JetStream with environment-scoped subjects,
    overlap guards, DLQ routing, retries/backoff, and optional Inbox/Outbox patterns.
    Includes topology setup helpers for production-safe operation.
  DESC

  spec.license     = 'MIT'
  spec.homepage    = 'https://github.com/attaradev/jetstream_bridge'

  # Ruby & RubyGems requirements
  spec.required_ruby_version     = '>= 2.7.0'
  spec.required_rubygems_version = '>= 3.3.0'

  # Rich metadata for RubyGems.org
  spec.metadata = {
    'homepage_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'source_code_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'changelog_uri' => 'https://github.com/attaradev/jetstream_bridge/blob/main/CHANGELOG.md',
    'documentation_uri' => 'https://github.com/attaradev/jetstream_bridge#readme',
    'bug_tracker_uri' => 'https://github.com/attaradev/jetstream_bridge/issues',
    'github_repo' => 'ssh://github.com/attaradev/jetstream_bridge',
    'rubygems_mfa_required' => 'true'
  }

  # Safer file list for published gem
  # (falls back to Dir[] if not in a git repo — e.g., CI tarballs)
  spec.files = if system('git rev-parse --is-inside-work-tree > /dev/null 2>&1')
                 `git ls-files -z`.split("\x0").reject { |f| f.start_with?('spec/fixtures/') }
               else
                 Dir['lib/**/*', 'README*', 'CHANGELOG*', 'LICENSE*']
               end

  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'activerecord',  '>= 6.0'
  spec.add_dependency 'activesupport', '>= 6.0'
  spec.add_dependency 'nats-pure',     '~> 2.4'
  spec.add_dependency 'rails',         '>= 6.0'

  # Development / quality dependencies
  spec.add_development_dependency 'bundler-audit',       '>= 0.9.1'
  spec.add_development_dependency 'rake',                '>= 13.0'
  spec.add_development_dependency 'rspec',               '>= 3.12'
  spec.add_development_dependency 'rubocop',             '~> 1.66'
  spec.add_development_dependency 'rubocop-packaging',   '~> 0.5'
  spec.add_development_dependency 'rubocop-performance', '~> 1.21'
end
