# Jetstream Bridge

Production-safe realtime data bridge between systems using **NATS JetStream**.  
Includes durable consumers, backpressure, retries, **DLQ**, and optional **Inbox/Outbox** for end-to-end reliability.

## Features

- 🔌 Simple **Publisher** and **Consumer**
- 🧰 **CLI**: `jetstream_bridge_setup`, `jetstream_bridge_consumer`, `jetstream_bridge_outbox_flush`
- 🛡 Optional **Outbox** (reliable send) & **Inbox** (idempotent receive)
- 🧨 **DLQ** for poison messages
- ⚙️ Durable `pull_subscribe` with backoff & `max_deliver`
- 🎯 Configurable **source** and **destination** applications

## Install

```ruby
# Gemfile
gem "jetstream_bridge", git: "https://github.com/attaradev/jetstream_bridge"
````

```bash
bundle install
```

## Configure (Rails)

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |c|
  c.nats_urls = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  c.env = Rails.env
  c.app_name = ENV.fetch("APP_NAME", "myapp")

  # Optionally set source/destination app names for filtering
  c.source_app = ENV["SOURCE_APP"] || c.app_name
  c.destination_app = ENV["DEST_APP"]

  c.stream_name = "#{Rails.env}-data-sync"
  c.dlq_subject = "#{Rails.env}.data.sync.dlq"

  c.max_deliver = 5
  c.ack_wait = "30s"
  c.backoff = %w[1s 5s 15s 30s 60s]

  # Reliability toggles
  c.use_outbox = true
  c.use_inbox = true

  # Models (override if you have your own)
  c.outbox_model = "JetstreamBridge::OutboxEvent"
  c.inbox_model = "JetstreamBridge::InboxEvent"

  # Keep publisher connection open in long-lived processes
  c.publisher_persistent = true
end

# Or use hash-style config (can be combined with block)
JetstreamBridge.configure(
  app_name: "myapp",
  source_app: "myapp",
  destination_app: "peerapp"
)
```

## DB Migrations (only if Inbox/Outbox enabled)

```ruby
# Outbox
create_table :jetstream_outbox_events, id: :uuid do |t|
  t.string  :resource_type, null: false
  t.string  :resource_id,   null: false
  t.string  :event_type,    null: false
  t.jsonb   :payload,       null: false, default: {}
  t.datetime :published_at
  t.integer  :attempts,     default: 0
  t.text     :last_error
  t.timestamps
end
add_index :jetstream_outbox_events, [:resource_type, :resource_id]

# Inbox
create_table :jetstream_inbox_events, id: :uuid do |t|
  t.string   :event_id,  null: false
  t.string   :subject,   null: false
  t.datetime :processed_at
  t.text     :error
  t.timestamps
end
add_index :jetstream_inbox_events, :event_id, unique: true
```

## Bootstrap NATS

```bash
bundle exec jetstream_bridge_setup
# Or limit to specific resources:
bundle exec jetstream_bridge_setup --only stream
bundle exec jetstream_bridge_setup --only dlq
bundle exec jetstream_bridge_setup --only source
bundle exec jetstream_bridge_setup --only destination
```

> `source` and `destination` refer to the configured `source_app` and `destination_app`.

## Publish

```ruby
PUBLISHER ||= JetstreamBridge::Publisher.new # persistent

PUBLISHER.publish(
  resource_type: "user",
  event_type:    "created",
  payload:       { id: "01H...", name: "Ada" }
)
```

> Short-lived script? Use ephemeral mode:

```ruby
JetstreamBridge::Publisher.new(persistent: false).publish(
  resource_type: "user",
  event_type: "created",
  payload: { id: "01H...", name: "Ada" }
)
```

## Outbox (if enabled)

Writes to Outbox on publish; flush later:

```ruby
# Job (recommended every minute)
class OutboxFlushJob < ApplicationJob
  def perform
    JetstreamBridge::Publisher.new.flush_outbox
  end
end
```

Or CLI (under Rails env):

```bash
bundle exec rails runner bin/jetstream_bridge_outbox_flush
```

## Consume

CLI:

```bash
bundle exec jetstream_bridge_consumer --source peerapp --durable prod-peerapp-events
```

Inside Rails:

```ruby
JetstreamBridge::Consumer.new(
  source_filter: JetstreamBridge.config.destination_app,
  durable_name:  "#{Rails.env}-peerapp-events",
  batch_size:    25
) do |event, subject, deliveries|
  # idempotent domain logic here
end.run!
```

## Envelope

Publisher sends:

```json
{
  "event_id": "ULID/UUID",
  "schema_version": 1,
  "producer": "myapp",
  "resource_type": "user",
  "resource_id": "01H...",
  "event_type": "created",
  "occurred_at": "2025-08-13T21:00:00Z",
  "trace_id": "abc123",
  "payload": { /* your fields */ }
}
```

## Ops Tips

* Monitor consumer lag (`nats consumer info <stream> <durable>`).
* Alert on Outbox growth & DLQ message count.
* Keep consumers in separate processes/containers (scale independently).
* Use Inbox when replays or duplicates are possible.
* Use Outbox when “DB commit ⇒ event is guaranteed” is required.

## License

[MIT LICENSE](LICENSE)
