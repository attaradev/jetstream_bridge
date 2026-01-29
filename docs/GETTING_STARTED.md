# Getting Started

This guide covers installation, Rails setup, configuration, and basic publish/consume flows.

## Install

```ruby
# Gemfile
gem "jetstream_bridge", "~> 5.0"
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

### Database Migrations

The generated migrations create tables for inbox and outbox patterns:

**Outbox Events** (`jetstream_bridge_outbox_events`):

```ruby
create_table :jetstream_bridge_outbox_events do |t|
  t.string :event_id, null: false, index: { unique: true }
  t.string :event_type, null: false
  t.string :resource_type, null: false
  t.string :resource_id
  t.jsonb :payload, default: {}, null: false
  t.string :subject, null: false
  t.jsonb :headers, default: {}
  t.string :status, default: "pending", null: false, index: true
  t.text :error_message
  t.integer :publish_attempts, default: 0
  t.datetime :published_at, index: true
  t.datetime :failed_at
  t.timestamps
end
```

**Inbox Events** (`jetstream_bridge_inbox_events`):

```ruby
create_table :jetstream_bridge_inbox_events do |t|
  t.string :event_id, null: false, index: { unique: true }
  t.string :event_type
  t.string :resource_type
  t.string :resource_id
  t.jsonb :payload, default: {}, null: false
  t.string :subject, null: false
  t.jsonb :headers, default: {}
  t.string :stream
  t.bigint :stream_seq, index: true
  t.integer :deliveries, default: 0
  t.string :status, default: "received", null: false, index: true
  t.text :error_message
  t.integer :processing_attempts, default: 0
  t.datetime :received_at, index: true
  t.datetime :processed_at, index: true
  t.datetime :failed_at
  t.timestamps
end
```

**Key Fields:**

- `event_id`: Unique identifier for deduplication
- `event_type`: Type of event (e.g., "user.created")
- `resource_type`/`resource_id`: Entity being synchronized
- `payload`: Event data (JSON)
- `status`: Event lifecycle state (pending/processing/processed/failed)
- `stream_seq`: NATS JetStream sequence number (inbox only)
- `deliveries`: Delivery attempt count (inbox only)

## Configuration

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.stream_name     = ENV.fetch("JETSTREAM_STREAM_NAME", "jetstream-bridge-stream")
  config.app_name        = "my_app"
  config.destination_app = ENV.fetch("DESTINATION_APP")

  config.use_outbox = true  # transactional publish
  config.use_inbox  = true  # idempotent consume
  config.use_dlq    = true  # route poison messages

  # Consumer tuning
  config.max_deliver = 5
  config.ack_wait    = "30s"
  config.backoff     = %w[1s 5s 15s 30s 60s]
end

# Note: `configure` only sets options; it does not connect. Rails will start
# JetstreamBridge after initialization via the Railtie. For non-Rails or custom
# boot flows, call `JetstreamBridge.startup!` (or rely on auto-connect on first
# publish/subscribe).
```

Rails autostart runs after initialization (including in console). You can opt out for rake tasks or other tooling with `config.lazy_connect = true` or `JETSTREAM_BRIDGE_DISABLE_AUTOSTART=1`; it will then connect on first publish/subscribe.

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
