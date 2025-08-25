# Jetstream Bridge

**Production-safe realtime data bridge** between systems using **NATS JetStream**.
Includes durable consumers, backpressure, retries, **DLQ**, optional **Inbox/Outbox**, and **overlap-safe stream provisioning**.

---

## ✨ Features

* 🔌 Simple **Publisher** and **Consumer** interfaces
* 🛡 **Outbox** (reliable send) & **Inbox** (idempotent receive), opt-in
* 🧨 **DLQ** for poison messages
* ⚙️ Durable `pull_subscribe` with backoff & `max_deliver`
* 🎯 Clear **source/destination** subject conventions
* 🧱 **Overlap-safe stream ensure** (prevents “subjects overlap” BadRequest)
* 🚂 **Rails generators** for initializer & migrations, plus an install **rake task**
* ⚡️ **Eager-loaded models** via Railtie (production)
* 📊 Built-in logging for visibility

---

## 📦 Install

```ruby
# Gemfile
gem "jetstream_bridge", "~> 2.6"
```

```bash
bundle install
```

---

## 🧰 Rails Generators & Rake Task

From your Rails app:

```bash
# Create initializer + migrations
bin/rails g jetstream_bridge:install

# Or run them separately:
bin/rails g jetstream_bridge:initializer
bin/rails g jetstream_bridge:migrations

# Rake task (does both initializer + migrations)
bin/rake jetstream_bridge:install
```

Then:

```bash
bin/rails db:migrate
```

> The generators create:
>
> * `config/initializers/jetstream_bridge.rb`
> * `db/migrate/*_create_jetstream_outbox_events.rb`
> * `db/migrate/*_create_jetstream_inbox_events.rb`

---

## 🔧 Configure (Rails)

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # NATS connection
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.env             = ENV.fetch("NATS_ENV",  "development")
  config.app_name        = ENV.fetch("APP_NAME",  "app")
  config.destination_app = ENV["DESTINATION_APP"] # required

  # Consumer tuning
  config.max_deliver = 5
  config.ack_wait    = "30s"
  config.backoff     = %w[1s 5s 15s 30s 60s]

  # Reliability features (opt-in)
  config.use_outbox = true
  config.use_inbox  = true
  config.use_dlq    = true

  # Models (override if you use custom AR classes/table names)
  config.outbox_model = "JetstreamBridge::OutboxEvent"
  config.inbox_model  = "JetstreamBridge::InboxEvent"
end
```

> **Defaults:**
>
> * `stream_name` → `#{env}-jetstream-bridge-stream`
> * `dlq_subject` → `#{env}.data.sync.dlq`

---

## 📡 Subject Conventions

| Direction     | Subject Pattern           |
|---------------|---------------------------|
| **Publish**   | `{env}.{app}.sync.{dest}` |
| **Subscribe** | `{env}.{dest}.sync.{app}` |
| **DLQ**       | `{env}.sync.dlq`          |

* `{app}`: `app_name`
* `{dest}`: `destination_app`
* `{env}`: `env`

---

## 🧱 Stream Topology (auto-ensure and overlap-safe)

On first connection, Jetstream Bridge **ensures** a single stream exists for your `env` and that it covers:

* `source_subject` (`{env}.{app}.sync.{dest}`)
* `destination_subject` (`{env}.{dest}.sync.{app}`)
* `dlq_subject` (if enabled)

It’s **overlap-safe**:

* Skips adding subjects already covered by existing wildcards
* Pre-filters subjects owned by other streams to avoid `BadRequest: subjects overlap with an existing stream`
* Retries once on concurrent races, then logs and continues safely

---

## 🗃 Database Setup (Inbox / Outbox)

Inbox/Outbox are **optional**. The library detects columns at runtime and only sets what exists, so you can start minimal and evolve later.

### Generator-created tables (recommended)

```ruby
# jetstream_outbox_events
create_table :jetstream_outbox_events do |t|
  t.string  :event_id, null: false
  t.string  :subject,  null: false
  t.jsonb   :payload,  null: false, default: {}
  t.jsonb   :headers,  null: false, default: {}
  t.string  :status,   null: false, default: "pending" # pending|publishing|sent|failed
  t.integer :attempts, null: false, default: 0
  t.text    :last_error
  t.datetime :enqueued_at
  t.datetime :sent_at
  t.timestamps
end
add_index :jetstream_outbox_events, :event_id, unique: true
add_index :jetstream_outbox_events, :status

# jetstream_inbox_events
create_table :jetstream_inbox_events do |t|
  t.string   :event_id                              # preferred dedupe key
  t.string   :subject,     null: false
  t.jsonb    :payload,     null: false, default: {}
  t.jsonb    :headers,     null: false, default: {}
  t.string   :stream
  t.bigint   :stream_seq
  t.integer  :deliveries
  t.string   :status,      null: false, default: "received" # received|processing|processed|failed
  t.text     :last_error
  t.datetime :received_at
  t.datetime :processed_at
  t.timestamps
end
add_index :jetstream_inbox_events, :event_id, unique: true, where: 'event_id IS NOT NULL'
add_index :jetstream_inbox_events, [:stream, :stream_seq], unique: true, where: 'stream IS NOT NULL AND stream_seq IS NOT NULL'
add_index :jetstream_inbox_events, :status
```

> Already have different table names? Point the config to your AR classes via `config.outbox_model` / `config.inbox_model`.

---

## 📤 Publish Events

```ruby
publisher = JetstreamBridge::Publisher.new
publisher.publish(
  resource_type: "user",
  event_type:    "created",
  payload:       { id: "01H...", name: "Ada" },  # resource_id inferred from payload[:id] / payload["id"]
  # optional:
  # event_id: "uuid-or-ulid",
  # trace_id: "hex",
  # occurred_at: Time.now.utc
)
```

If **Outbox** is enabled, the publish call:

* Upserts an outbox row by `event_id`
* Publishes with `nats-msg-id` (idempotent)
* Marks status `sent` or records `failed` with `last_error`

---

## 📥 Consume Events

```ruby
JetstreamBridge::Consumer.new(
  durable_name: "#{Rails.env}-#{app_name}-workers",
  batch_size:   25
) do |event, subject, deliveries|
  # Your idempotent domain logic here
  # `event` is the parsed envelope hash
  UserCreatedHandler.call(event["payload"])
end.run!
```

If **Inbox** is enabled, the consumer:

* Dedupes by `event_id` (falls back to stream sequence if needed)
* Records processing state, errors, and timestamps
* Skips already-processed messages (acks immediately)

---

## 📬 Envelope Format

```json
{
  "event_id":       "01H1234567890ABCDEF",
  "schema_version": 1,
  "event_type":     "created",
  "producer":       "myapp",
  "resource_type":  "user",
  "resource_id":    "01H1234567890ABCDEF",
  "occurred_at":    "2025-08-13T21:00:00Z",
  "trace_id":       "abc123",
  "payload":        { "id": "01H...", "name": "Ada" }
}
```

* `resource_id` is inferred from `payload.id` when publishing.

---

## 🧨 Dead-Letter Queue (DLQ)

When enabled, the topology ensures the DLQ subject exists:
**`{env}.data.sync.dlq`**

You may run a separate process to subscribe and triage messages that exceed `max_deliver` or are NAK’ed to the DLQ.

---

## 🛠 Operations Guide

### Monitoring

* **Consumer lag**: `nats consumer info <stream> <durable>`
* **DLQ volume**: subscribe/metrics on `{env}.data.sync.dlq`
* **Outbox backlog**: alert on `jetstream_outbox_events` with `status != 'sent'` and growing count

### Scaling

* Run consumers in **separate processes/containers**
* Scale consumers independently of web
* Tune `batch_size`, `ack_wait`, `max_deliver`, and `backoff`

### Health check

* Force-connect & ensure topology at boot or in a check:

  ```ruby
  # Returns JetStream context if successful
  JetstreamBridge.ensure_topology!
  ```

### When to Use

* **Inbox**: you need idempotent processing and replay safety
* **Outbox**: you want “DB commit ⇒ event published (or recorded for retry)” guarantees

---

## 🧩 Troubleshooting

* **`subjects overlap with an existing stream`**
  The library pre-filters overlapping subjects and retries once. If another team owns a broad wildcard (e.g., `env.data.sync.>`), coordinate subject boundaries.

* **Consumer exists with mismatched filter**
  The library detects and recreates the durable with the desired filter subject.

* **Repeated redeliveries**
  Increase `ack_wait`, review handler acks/NACKs, or move poison messages to DLQ.

---

## 🚀 Getting Started

1. Add the gem & run `bundle install`
2. `bin/rails g jetstream_bridge:install`
3. `bin/rails db:migrate`
4. Start publishing/consuming!

---

## 📄 License

[MIT License](LICENSE)
