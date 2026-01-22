<p align="center">
  <img src="logo.svg" alt="JetStream Bridge Logo" width="200"/>
</p>

<p align="center">
  <a href="https://github.com/attaradev/jetstream_bridge/actions/workflows/ci.yml">
    <img src="https://github.com/attaradev/jetstream_bridge/actions/workflows/ci.yml/badge.svg" alt="CI Status"/>
  </a>
  <a href="https://codecov.io/gh/attaradev/jetstream_bridge">
    <img src="https://codecov.io/gh/attaradev/jetstream_bridge/branch/main/graph/badge.svg" alt="Coverage Status"/>
  </a>
  <a href="https://rubygems.org/gems/jetstream_bridge">
    <img src="https://img.shields.io/gem/v/jetstream_bridge.svg" alt="Gem Version"/>
  </a>
  <a href="https://rubygems.org/gems/jetstream_bridge">
    <img src="https://img.shields.io/gem/dt/jetstream_bridge.svg" alt="Downloads"/>
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"/>
  </a>
</p>

Production-ready NATS JetStream bridge for Ruby/Rails with outbox, inbox, DLQ, and overlap-safe stream provisioning.

## Highlights

- Transactional outbox and idempotent inbox (optional) for exactly-once pipelines.
- Durable pull consumers with retries, backoff, and DLQ routing.
- Auto stream/consumer provisioning with overlap protection.
- Rails-native: generators, migrations, health check, and eager-loading safety.
- Mock NATS for fast, no-infra testing.

## Quick Start

```ruby
# Gemfile
gem "jetstream_bridge", "~> 4.0"
```

```bash
bundle install
bin/rails g jetstream_bridge:install
bin/rails db:migrate
```

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.app_name        = "my_app"
  config.destination_app = "worker_app"
  config.stream_name     = "my_app-jetstream-bridge-stream"
  config.use_outbox = true
  config.use_inbox  = true
  config.use_dlq    = true
end
```

Publish:

```ruby
JetstreamBridge.publish(event_type: "user.created", resource_type: "user", payload: { id: 1 })
```

Consume:

```ruby
consumer = JetstreamBridge::Consumer.new do |event|
  User.upsert({ id: event.payload["id"] })
end
consumer.run!
```

## Documentation

- [Getting Started](docs/GETTING_STARTED.md)
- [Production Guide](docs/PRODUCTION.md)
- [Testing with Mock NATS](docs/TESTING.md)

## License

MIT
