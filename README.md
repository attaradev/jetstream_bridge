# Jetstream Bridge

Production-safe realtime data bridge between systems using **NATS JetStream**.
Includes durable consumers, backpressure, retries, **DLQ**, and optional **Inbox/Outbox** for end-to-end reliability.

---

## Features

- 🔌 Simple **Publisher** and **Consumer**
- 🛡 Optional **Outbox** (reliable send) & **Inbox** (idempotent receive)
- 🧨 **DLQ** for poison messages
- ⚙️ Durable `pull_subscribe` with backoff & `max_deliver`
- 🎯 Configurable **source** and **destination** applications

---

## Install

```ruby
# Gemfile
gem "jetstream_bridge"
```

```bash
bundle install
```

---

## Configure (Rails)

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge::Config.new.tap do |c|
  c.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  c.env             = ENV.fetch("NATS_ENV", "development")
  c.app_name        = ENV.fetch("APP_NAME", "app")
  c.destination_app = ENV["DESTINATION_APP"]

  c.max_deliver = 5
  c.ack_wait    = "30s"
  c.backoff     = %w[1s 5s 15s 30s 60s]

  # Reliability toggles
  c.use_outbox = true
  c.use_inbox  = true
  c.use_dlq    = true

  # Models (override if you have your own)
  c.outbox_model = "JetstreamBridge::OutboxEvent"
  c.inbox_model  = "JetstreamBridge::InboxEvent"
end
```

> **Note:** `stream_name` and `dlq_subject` are derived from `env`.
> Default stream name: `{env}-stream-bridge`
> Default DLQ subject: `data.sync.dlq`

---

## Subject Conventions

| Direction | Subject Pattern                             |
|-----------|---------------------------------------------|
| Publish   | `data.sync.{app}.{dest}.{resource}.{event}` |
| Subscribe | `data.sync.{dest}.{app}.>`                  |
| DLQ       | `data.sync.dlq`                             |

- `{app}`: Your application name (`app_name`)
- `{dest}`: Destination application (`destination_app`)

---

## DB Migrations (only if Inbox/Outbox enabled)

```ruby
# Outbox
create_table :jetstream_outbox_events do |t|
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
create_table :jetstream_inbox_events do |t|
  t.string   :event_id,  null: false
  t.string   :subject,   null: false
  t.datetime :processed_at
  t.text     :error
  t.timestamps
end
add_index :jetstream_inbox_events, :event_id, unique: true
```

---

## Publish

```ruby
publisher = JetstreamBridge::Publisher.new
publisher.publish(
  resource_type: "user",
  event_type:    "created",
  payload:       { id: "01H...", name: "Ada" }
)
```

> For short-lived scripts, use ephemeral mode:
 ```ruby
  JetstreamBridge::Publisher.new(persistent: false).publish(...)
> ```

---

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

---

## Consume

Inside Rails:

```ruby
JetstreamBridge::Consumer.new(
  source_filter: JetstreamBridge.config.dest_subject,
  durable_name:  "#{Rails.env}-peerapp-events",
  batch_size:    25
) do |event, subject, deliveries|
  # idempotent domain logic here
end.run!
```

---

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

---

## Ops Tips

* Monitor consumer lag (`nats consumer info <stream> <durable>`).
* Alert on Outbox growth & DLQ message count.
* Keep consumers in separate processes/containers (scale independently).
* Use Inbox when replays or duplicates are possible.
* Use Outbox when “DB commit ⇒ event is guaranteed” is required.

---

## License

[MIT LICENSE](LICENSE)
