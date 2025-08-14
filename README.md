# Jetstream Bridge

**Production-safe realtime data bridge** between systems using **NATS JetStream**.
Includes durable consumers, backpressure, retries, **DLQ**, and optional **Inbox/Outbox** for end-to-end reliability.

---

## ✨ Features

- 🔌 Simple **Publisher** and **Consumer** interfaces
- 🛡 **Outbox** (reliable send) & **Inbox** (idempotent receive)
- 🧨 **DLQ** for poison messages
- ⚙️ Durable `pull_subscribe` with exponential backoff & `max_deliver`
- 🎯 Configurable **source** and **destination** applications
- 📊 Built-in observability

---

## 📦 Install

```ruby
# Gemfile
gem "jetstream_bridge"
```

```bash
bundle install
```

---

## 🔧 Configure (Rails)

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # NATS Connection
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.env             = ENV.fetch("NATS_ENV", "development")
  config.app_name        = ENV.fetch("APP_NAME", "app")
  config.destination_app = ENV["DESTINATION_APP"]

  # Consumer Tuning
  config.max_deliver = 5
  config.ack_wait    = "30s"
  config.backoff     = %w[1s 5s 15s 30s 60s]

  # Reliability Features
  config.use_outbox = true
  config.use_inbox  = true
  config.use_dlq    = true

  # Models (override if custom)
  config.outbox_model = "JetstreamBridge::OutboxEvent"
  config.inbox_model  = "JetstreamBridge::InboxEvent"
end
```

> **Note:**
> - `stream_name` defaults to `{env}-stream-bridge`
> - `dlq_subject` defaults to `data.sync.dlq`

---

## 📡 Subject Conventions

| Direction     | Subject Pattern                                   |
|---------------|---------------------------------------------------|
| **Publish**   | `{env}.data.sync.{app}.{dest}.{resource}.{event}` |
| **Subscribe** | `{env}.data.sync.{dest}.{app}.>`                  |
| **DLQ**       | `{env}.data.sync.dlq`                             |

- `{app}`: Your `app_name`
- `{dest}`: Your `destination_app`
- `{resource}`: The resource type (e.g. `user`)
- `{event}`: The event type (e.g. `created`)
- `{env}`: Your `env``

---

## 🗃 Database Setup (Inbox/Outbox)

Run the installer:

```bash
rails jetstream_bridge:install --all
```

This creates:

1. **Initializer** (`config/initializers/jetstream_bridge.rb`)
2. **Migrations** (if enabled):

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

## 📤 Publish Events

```ruby
publisher = JetstreamBridge::Publisher.new
publisher.publish(
  resource_type: "user",
  resource_id:   "01H1234567890ABCDEF",
  event_type:    "created",
  payload:       { id: "01H...", name: "Ada" }
)
```

> **Ephemeral Mode** (for short-lived scripts):
> ```ruby
> JetstreamBridge::Publisher.new(persistent: false).publish(...)
> ```

---

## 🔄 Outbox (If Enabled)

Events are written to the Outbox table. Flush periodically:

```ruby
# app/jobs/outbox_flush_job.rb
class OutboxFlushJob < ApplicationJob
  def perform
    JetstreamBridge::Publisher.new.flush_outbox
  end
end
```

Schedule this job to run every minute.

---

## 📥 Consume Events

```ruby
JetstreamBridge::Consumer.new(
  durable_name: "#{Rails.env}-peerapp-events",
  batch_size:   25
) do |event, subject, deliveries|
  # Your idempotent domain logic here
  UserCreatedHandler.call(event.payload)
end.run!
```

---

## 📬 Envelope Format

Published events include:

```json
{
  "event_id":       "01H1234567890ABCDEF",
  "schema_version": 1,
  "producer":       "myapp",
  "resource_type":  "user",
  "resource_id":    "01H1234567890ABCDEF",
  "event_type":     "created",
  "occurred_at":    "2025-08-13T21:00:00Z",
  "trace_id":       "abc123",
  "payload":        { "id": "01H...", "name": "Ada" }
}
```

---

## 🛠 Operations Guide

### Monitoring
- **Consumer Lag**: `nats consumer info <stream> <durable>`
- **Outbox Growth**: Alert if `jetstream_outbox_events` grows unexpectedly
- **DLQ Messages**: Monitor `data.sync.dlq` subscription

### Scaling
- Run consumers in **separate processes/containers**
- Scale independently of web workers

### When to Use
- **Inbox**: When replays or duplicates are possible
- **Outbox**: When "DB commit ⇒ event published" guarantee is required

---

## 🚀 Getting Started

1. Install the gem 
2. Configure the initializer 
3. Run migrations: `rails db:migrate`
4. Start publishing/consuming!

---

## 📄 License

[MIT License](LICENSE)
