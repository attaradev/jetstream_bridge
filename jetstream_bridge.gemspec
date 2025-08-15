# frozen_string_literal: true

require_relative 'lib/jetstream_bridge/version'

Gem::Specification.new do |spec|
  spec.name                  = 'jetstream_bridge'
  spec.version               = JetstreamBridge::VERSION
  spec.authors               = ['Mike Attara']
  spec.email                 = ['mpyebattara@gmail.com']
  spec.summary               = 'Production-safe realtime data bridge over NATS JetStream'
  spec.description           = 'Publisher/Consumer with optional Inbox/Outbox, DLQ, retries, and setup helpers.'
  spec.license               = 'MIT'
  spec.homepage              = 'https://github.com/attaradev/jetstream_bridge'

  spec.metadata = {
    'source_code_uri'      => 'https://github.com/attaradev/jetstream_bridge',
    'changelog_uri'        => 'https://github.com/attaradev/jetstream_bridge/blob/main/CHANGELOG.md',
    'documentation_uri'    => 'https://github.com/attaradev/jetstream_bridge#readme',
    'bug_tracker_uri'      => 'https://github.com/attaradev/jetstream_bridge/issues',
    'homepage_uri'         => 'https://github.com/attaradev/jetstream_bridge',
    'rubygems_mfa_required' => 'true',
    'required_ruby_version' => '>= 2.7.0'
  }

  spec.files                 = Dir['lib/**/*', 'README.md', 'LICENSE*']
  spec.require_paths         = ['lib']
  spec.required_ruby_version = '>= 2.7.0'

  # Runtime dependencies
  spec.add_dependency 'nats-pure',     '~> 2.4'
  spec.add_dependency 'activesupport', '>= 6.0'
  spec.add_dependency 'activerecord',  '>= 6.0', optional: true
  spec.add_dependency 'rails',         '>= 6.0', optional: true

  # Development dependencies
  spec.add_development_dependency 'rubocop',             '~> 1.66'
  spec.add_development_dependency 'rubocop-packaging',   '~> 0.5'
  spec.add_development_dependency 'rubocop-performance', '~> 1.21'
  spec.add_development_dependency 'rubocop-rake',        '~> 0.6'
end
