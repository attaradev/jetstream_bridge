# Getting Started

This guide covers installation, Rails setup, configuration, and basic publish/consume flows.

## Install

```ruby
# Gemfile
gem "jetstream_bridge", "~> 4.0"
```

```bash
bundle install
```

## Rails Setup

Generate initializer, migrations, and optional health check:

```bash
bin/rails g jetstream_bridge:install
# or separately:
bin/rails g jetstream_bridge:initializer
bin/rails g jetstream_bridge:migrations
bin/rails g jetstream_bridge:health_check
bin/rails db:migrate
```

Generators create:

- `config/initializers/jetstream_bridge.rb`
- `db/migrate/*_create_jetstream_outbox_events.rb`
- `db/migrate/*_create_jetstream_inbox_events.rb`
- `app/controllers/jetstream_health_controller.rb` (health check)

## Configuration

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.app_name        = "my_app"
  config.destination_app = ENV.fetch("DESTINATION_APP")
  config.stream_name     = "my_app-jetstream-bridge-stream" # required

  config.use_outbox = true  # transactional publish
  config.use_inbox  = true  # idempotent consume
  config.use_dlq    = true  # route poison messages

  # Consumer tuning
  config.max_deliver = 5
  config.ack_wait    = "30s"
  config.backoff     = %w[1s 5s 15s 30s 60s]

  # Optional: Custom inbox prefix if NATS account restricts _INBOX.>
  # config.inbox_prefix = "$RPC"

  # Optional: Pre-provisioned stream/consumer names
  # config.durable_name = "my-durable"

  # Optional: Disable JetStream management APIs (requires pre-provisioning)
  # config.disable_js_api = false
end
```

Rails starts JetStream Bridge automatically after initialization. For non-Rails apps, call `JetstreamBridge.connect!` or rely on auto-connect on first publish/subscribe.

## Publish

```ruby
JetstreamBridge.publish(
  event_type: "user.created",
  resource_type: "user",
  payload: { id: user.id, email: user.email }
)
```

## Consume

```ruby
consumer = JetstreamBridge::Consumer.new do |event|
  user = event.payload
  User.upsert({ id: user["id"], email: user["email"] })
end

consumer.run!
```

## Rake Tasks

```bash
bin/rake jetstream_bridge:health         # Check health/connection
bin/rake jetstream_bridge:validate       # Validate configuration
bin/rake jetstream_bridge:test_connection# Test NATS connectivity
bin/rake jetstream_bridge:debug          # Dump debug info
```

## Next Steps

- Production hardening: [docs/PRODUCTION.md](PRODUCTION.md)
- Testing with Mock NATS: [docs/TESTING.md](TESTING.md)
