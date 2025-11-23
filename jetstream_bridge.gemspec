# frozen_string_literal: true

require_relative 'lib/jetstream_bridge/version'

Gem::Specification.new do |spec|
  spec.name    = 'jetstream_bridge'
  spec.version = JetstreamBridge::VERSION
  spec.authors = ['Mike Attara']
  spec.email   = ['mpyebattara@gmail.com']

  spec.summary     = 'Production-safe realtime data bridge using NATS JetStream'
  spec.description = <<~DESC.strip
    Publisher/Consumer utilities for NATS JetStream with environment-scoped subjects,
    overlap guards, DLQ routing, retries/backoff, and optional Inbox/Outbox patterns.
    Includes health checks, auto-reconnection, graceful shutdown, and topology setup
    helpers for production-safe operation.
  DESC

  spec.license  = 'MIT'
  spec.homepage = 'https://github.com/attaradev/jetstream_bridge'

  spec.required_ruby_version = '>= 3.2.0'

  # Metadata for RubyGems.org
  spec.metadata = {
    'homepage_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'source_code_uri' => 'https://github.com/attaradev/jetstream_bridge',
    'changelog_uri' => 'https://github.com/attaradev/jetstream_bridge/blob/main/CHANGELOG.md',
    'documentation_uri' => 'https://rubydoc.info/gems/jetstream_bridge',
    'bug_tracker_uri' => 'https://github.com/attaradev/jetstream_bridge/issues',
    'rubygems_mfa_required' => 'true',
    'allowed_push_host' => 'https://rubygems.org'
  }

  # Specify which files should be included in the gem
  spec.files = Dir.chdir(__dir__) do
    Dir[
      'lib/**/*.rb',
      'lib/**/*.rake',
      'lib/**/templates/**/*',
      'README.md',
      'LICENSE',
      'CHANGELOG.md'
    ].select { |f| File.file?(f) }
  end

  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'activerecord',  '>= 7.1.5.2', '< 8.0'
  spec.add_dependency 'activesupport', '>= 7.1.5.2', '< 8.0'
  spec.add_dependency 'mutex_m'
  spec.add_dependency 'nats-pure',     '>= 2.4.0', '< 3.0'
  spec.add_dependency 'oj', '>= 3.16', '< 4.0'
end
