<p align="center">
  <img src="logo.svg" alt="JetStream Bridge Logo" width="200"/>
</p>

<h1 align="center">JetStream Bridge</h1>

<p align="center">
  <strong>Production-safe realtime data bridge</strong> between systems using <strong>NATS JetStream</strong>
</p>

<p align="center">
  Includes durable consumers, backpressure, retries, <strong>DLQ</strong>, optional <strong>Inbox/Outbox</strong>, and <strong>overlap-safe stream provisioning</strong>
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

<p align="center">
  <a href="#-why-jetstream-bridge">Why?</a> •
  <a href="#-features">Features</a> •
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-documentation">Documentation</a> •
  <a href="#-contributing">Contributing</a>
</p>

---

## 🎯 Why JetStream Bridge?

Building event-driven systems with NATS JetStream is powerful, but comes with challenges:

* **Reliability**: How do you guarantee messages aren't lost during deploys or network failures?
* **Idempotency**: How do you prevent duplicate processing when messages are redelivered?
* **Stream Management**: How do you avoid "subjects overlap" errors in production?
* **Monitoring**: How do you know if your consumers are healthy and processing messages?
* **Rails Integration**: How do you integrate cleanly with ActiveRecord transactions?

**JetStream Bridge solves these problems** with production-tested patterns:

* ✅ **Transactional Outbox** - Never lose events, even if NATS is down
* ✅ **Idempotent Inbox** - Process each message exactly once, safely
* ✅ **Automatic Stream Provisioning** - No more manual stream management or overlap conflicts
* ✅ **Built-in Health Checks** - K8s-ready monitoring endpoints
* ✅ **Rails-Native** - Works seamlessly with ActiveRecord and Rails conventions

---

## ✨ Features

### Core Capabilities

* 🔌 **Simple Publisher and Consumer interfaces** - Write event-driven code in minutes with intuitive APIs that abstract NATS complexity
* 🛡 **Outbox & Inbox patterns (opt-in)** - Guarantee exactly-once delivery with reliable send (Outbox) and idempotent receive (Inbox)
* 🧨 **Dead Letter Queue (DLQ)** - Isolate and triage poison messages automatically instead of blocking your entire pipeline
* ⚙️ **Durable pull subscriptions** - Never lose messages with configurable backoff strategies and max delivery attempts
* 🎯 **Clear subject conventions** - Organized source/destination routing that scales across multiple services
* 🧱 **Overlap-safe stream provisioning** - Automatically prevents "subjects overlap" errors with intelligent conflict detection
* 🚂 **Rails generators included** - Generate initializers, migrations, and health checks with a single command
* ⚡️ **Zero-downtime deploys** - Eager-loaded models via Railtie ensure production stability
* 📊 **Observable by default** - Configurable logging with sensible defaults for debugging and monitoring

### Production-Ready Reliability

* 🏥 **Built-in health checks** - Monitor NATS connection, stream status, and configuration for K8s readiness/liveness probes
* 🔄 **Automatic reconnection** - Recover from network failures and NATS restarts without manual intervention
* 🔒 **Race condition protection** - Pessimistic locking prevents duplicate publishes in high-concurrency scenarios
* 🛡️ **Transaction safety** - All database operations are atomic with automatic rollback on failures
* 🎯 **Subject validation** - Catch configuration errors early by preventing NATS wildcards where they don't belong
* 🚦 **Graceful shutdown** - Proper signal handling and message draining prevent data loss during deploys
* 📈 **Pluggable retry strategies** - Choose exponential or linear backoff, or implement your own custom strategy

---

## 🚀 Quick Start

### 1. Install the Gem

```ruby
# Gemfile
gem "jetstream_bridge", "~> 3.0"
```

```bash
bundle install
```

### 2. Generate Configuration and Migrations

```bash
# Creates initializer and migrations
bin/rails g jetstream_bridge:install

# Run migrations
bin/rails db:migrate
```

### 3. Configure Your Application

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls       = ENV.fetch("NATS_URLS", "nats://localhost:4222")
  config.env             = ENV.fetch("RAILS_ENV", "development")
  config.app_name        = "my_app"
  config.destination_app = "other_app"  # Required: The app you're communicating with

  # Enable reliability features (recommended for production)
  config.use_outbox = true  # Transactional outbox pattern
  config.use_inbox  = true  # Idempotent message processing
  config.use_dlq    = true  # Dead letter queue for failed messages
end
```

### 4. Publish Your First Event

```ruby
# In your Rails application
JetstreamBridge.publish(
  resource_type: "user",
  event_type: "created",
  payload: { id: user.id, email: user.email }
)
```

### 5. Consume Events

```ruby
# Create a consumer (e.g., in a rake task or separate process)
consumer = JetstreamBridge::Consumer.new do |event, subject, deliveries|
  user_data = event["payload"]
  # Your idempotent business logic here
  User.find_or_create_by(id: user_data["id"]) do |user|
    user.email = user_data["email"]
  end
end

consumer.run! # Starts consuming messages
```

That's it! You're now publishing and consuming events with JetStream.

---

## 📖 Documentation

### Table of Contents

* [Installation & Setup](#-rails-generators--rake-tasks)
* [Configuration](#-configuration)
* [Publishing Events](#-publish-events)
* [Consuming Events](#-consume-events)
* [Database Setup](#-database-setup-inbox--outbox)
* [Stream Topology](#-stream-topology-auto-ensure-and-overlap-safe)
* [Operations Guide](#-operations-guide)
* [Troubleshooting](#-troubleshooting)

---

## 🧰 Rails Generators & Rake Tasks

### Installation

From your Rails app:

```bash
# Create initializer + migrations
bin/rails g jetstream_bridge:install

# Or run them separately:
bin/rails g jetstream_bridge:initializer
bin/rails g jetstream_bridge:migrations

# Create health check endpoint
bin/rails g jetstream_bridge:health_check
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
> * `app/controllers/jetstream_health_controller.rb` (if health_check generator used)

### Rake Tasks

```bash
# Check health and connection status
bin/rake jetstream_bridge:health

# Validate configuration
bin/rake jetstream_bridge:validate

# Test NATS connection
bin/rake jetstream_bridge:test_connection

# Show comprehensive debug information
bin/rake jetstream_bridge:debug
```

---

## 🔧 Configuration

### Basic Configuration

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # === Required Settings ===

  # NATS server URLs (comma-separated for multiple servers)
  config.nats_urls = ENV.fetch("NATS_URLS", "nats://localhost:4222")

  # Environment namespace (development, staging, production)
  config.env = ENV.fetch("RAILS_ENV", "development")

  # Your application name (used in subject routing)
  config.app_name = ENV.fetch("APP_NAME", "my_app")

  # The application you're communicating with (REQUIRED)
  config.destination_app = ENV.fetch("DESTINATION_APP")

  # === Reliability Features (Recommended for Production) ===

  # Transactional Outbox: Ensures events are never lost
  config.use_outbox = true

  # Idempotent Inbox: Prevents duplicate processing
  config.use_inbox = true

  # Dead Letter Queue: Isolates poison messages
  config.use_dlq = true

  # === Consumer Tuning ===

  # Maximum delivery attempts before moving to DLQ
  config.max_deliver = 5

  # Time to wait for acknowledgment before redelivery
  config.ack_wait = "30s"

  # Backoff delays between retries (exponential backoff)
  config.backoff = %w[1s 5s 15s 30s 60s]

  # === Advanced Options ===

  # Custom ActiveRecord models (if you have your own tables)
  # config.outbox_model = "CustomOutboxEvent"
  # config.inbox_model = "CustomInboxEvent"

  # Custom logger
  # config.logger = Rails.logger
end
```

### Configuration Reference

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `nats_urls` | String | `"nats://localhost:4222"` | NATS server URL(s), comma-separated |
| `env` | String | `"development"` | Environment namespace for streams |
| `app_name` | String | (required) | Your application identifier |
| `destination_app` | String | (required) | Target application for events |
| `use_outbox` | Boolean | `false` | Enable transactional outbox pattern |
| `use_inbox` | Boolean | `false` | Enable idempotent inbox pattern |
| `use_dlq` | Boolean | `false` | Enable dead letter queue |
| `max_deliver` | Integer | `5` | Max delivery attempts before DLQ |
| `ack_wait` | String/Integer | `"30s"` | Acknowledgment timeout |
| `backoff` | Array | `["1s", "5s", "15s"]` | Retry backoff schedule |

### Understanding Configuration Options

#### When to Use Outbox

Enable `use_outbox` when you need:

* **Transactional guarantees**: Publish events as part of database transactions
* **Reliability**: Ensure events are never lost, even if NATS is temporarily down
* **Audit trail**: Keep a permanent record of all published events

```ruby
# Example: Publishing with outbox ensures atomicity
ActiveRecord::Base.transaction do
  user.save!
  JetstreamBridge.publish(
    resource_type: "user",
    event_type: "created",
    payload: { id: user.id }
  ) # Event is saved in outbox table first
end
```

#### When to Use Inbox

Enable `use_inbox` when you need:

* **Idempotency**: Process each message exactly once, even with redeliveries
* **Duplicate protection**: Prevent duplicate processing across restarts
* **Processing history**: Track which messages have been processed

```ruby
# Example: Inbox prevents duplicate processing
# Even if the message is redelivered, it will be skipped
# if already marked as processed
```

#### When to Use DLQ

Enable `use_dlq` when you need:

* **Poison message handling**: Isolate messages that repeatedly fail
* **Manual intervention**: Review and retry failed messages later
* **Pipeline protection**: Prevent one bad message from blocking the queue

### Logging Configuration

JetstreamBridge integrates with your application's logger:

```ruby
# Use Rails logger (default)
config.logger = Rails.logger

# Use custom logger
config.logger = Logger.new(STDOUT)

# Disable logging
config.logger = Logger.new(IO::NULL)
```

### Environment Variables

Recommended environment variable setup:

```bash
# .env (or your deployment configuration)
NATS_URLS=nats://nats1:4222,nats://nats2:4222,nats://nats3:4222
RAILS_ENV=production
APP_NAME=api_service
DESTINATION_APP=notification_service
```

### Generated Streams and Subjects

Based on your configuration, JetStream Bridge automatically creates:

* **Stream Name**: `{env}-jetstream-bridge-stream`
  * Example: `production-jetstream-bridge-stream`

* **Publish Subject**: `{env}.{app_name}.sync.{destination_app}`
  * Example: `production.api_service.sync.notification_service`

* **Subscribe Subject**: `{env}.{destination_app}.sync.{app_name}`
  * Example: `production.notification_service.sync.api_service`

* **DLQ Subject**: `{env}.sync.dlq`
  * Example: `production.sync.dlq`

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

JetStream Bridge provides two ways to publish events: a convenience method and a direct publisher instance.

### Using the Convenience Method (Recommended)

The simplest way to publish events:

```ruby
# Basic usage with structured parameters
JetstreamBridge.publish(
  resource_type: "user",
  event_type: "created",
  payload: { id: user.id, email: user.email, name: user.name }
)

# Returns true on success, raises error on failure
```

### Publishing Patterns

#### 1. Structured Parameters (Recommended)

Best for explicit, clear code:

```ruby
JetstreamBridge.publish(
  resource_type: "user",
  event_type: "created",
  payload: { id: "01H...", email: "ada@example.com" },
  # Optional parameters:
  event_id: SecureRandom.uuid,      # Auto-generated if not provided
  trace_id: request_id,              # For distributed tracing
  occurred_at: Time.now.utc,         # Defaults to current time
  subject: "custom.subject.override" # Override default subject
)
```

#### 2. Simplified Hash (Infers resource_type)

Use dot notation in `event_type` to infer `resource_type`:

```ruby
JetstreamBridge.publish(
  event_type: "user.created",  # "user" becomes resource_type
  payload: { id: "01H...", email: "ada@example.com" }
)
```

#### 3. Complete Envelope (Advanced)

Pass a full envelope hash for maximum control:

```ruby
JetstreamBridge.publish(
  event_type: "created",
  resource_type: "user",
  payload: { id: "01H...", email: "ada@example.com" },
  event_id: "custom-event-id",
  occurred_at: 1.hour.ago.iso8601,
  producer: "custom-producer"
)
```

### Using Publisher Instances

For more control or batch operations:

```ruby
publisher = JetstreamBridge::Publisher.new

# Publish multiple events
publisher.publish(
  resource_type: "user",
  event_type: "created",
  payload: { id: user.id }
)

publisher.publish(
  resource_type: "user",
  event_type: "updated",
  payload: { id: user.id, email: user.email }
)
```

### Publishing with Transactions (Outbox Pattern)

When `use_outbox` is enabled, events are saved to the database first:

```ruby
# Atomic: both user creation and event publishing succeed or fail together
ActiveRecord::Base.transaction do
  user = User.create!(email: "ada@example.com")

  JetstreamBridge.publish(
    resource_type: "user",
    event_type: "created",
    payload: { id: user.id, email: user.email }
  )
end
# Event is saved in outbox table, published to NATS asynchronously
```

### Outbox Behavior

If **Outbox** is enabled (`config.use_outbox = true`):

* ✅ Events are saved to `jetstream_outbox_events` table first
* ✅ Published with `nats-msg-id` header for idempotency
* ✅ Marked as `sent` on success or `failed` with error details
* ✅ Survives NATS downtime - events queued for retry
* ✅ Provides audit trail of all published events

### Real-World Examples

#### Publishing Domain Events

```ruby
# After user registration
class UsersController < ApplicationController
  def create
    ActiveRecord::Base.transaction do
      @user = User.create!(user_params)

      JetstreamBridge.publish(
        resource_type: "user",
        event_type: "registered",
        payload: {
          id: @user.id,
          email: @user.email,
          name: @user.name,
          plan: @user.plan
        },
        trace_id: request.request_id
      )
    end

    redirect_to @user
  end
end
```

#### Publishing State Changes

```ruby
# In your model or service object
class Order
  after_commit :publish_status_change, if: :saved_change_to_status?

  private

  def publish_status_change
    JetstreamBridge.publish(
      resource_type: "order",
      event_type: "status_changed",
      payload: {
        id: id,
        status: status,
        previous_status: status_before_last_save,
        changed_at: updated_at
      }
    )
  end
end
```

#### Publishing with Distributed Tracing

```ruby
# Include trace_id for correlation across services
JetstreamBridge.publish(
  resource_type: "payment",
  event_type: "processed",
  payload: { order_id: order.id, amount: payment.amount },
  trace_id: Current.request_id,
  event_id: payment.transaction_id
)
```

---

## 📥 Consume Events

JetStream Bridge provides two ways to consume events: a convenience method and direct consumer instances.

### Using the Convenience Method (Recommended)

The simplest way to start consuming events:

```ruby
# Start consumer and run in current thread
consumer = JetstreamBridge.subscribe do |event, subject, deliveries|
  user_data = event["payload"]
  User.find_or_create_by(id: user_data["id"]) do |user|
    user.email = user_data["email"]
  end
end

consumer.run! # Blocks and processes messages
```

### Consuming Patterns

#### 1. Basic Consumer with Block

```ruby
consumer = JetstreamBridge.subscribe do |event, subject, deliveries|
  # event: parsed envelope hash with all event data
  # subject: NATS subject the message was published to
  # deliveries: number of delivery attempts (starts at 1)

  case event["event_type"]
  when "created"
    UserCreatedHandler.call(event["payload"])
  when "updated"
    UserUpdatedHandler.call(event["payload"])
  when "deleted"
    UserDeletedHandler.call(event["payload"])
  end
end

consumer.run! # Start consuming
```

#### 2. Run Consumer in Background Thread

```ruby
# Returns a Thread instead of Consumer
thread = JetstreamBridge.subscribe(run: true) do |event, subject, deliveries|
  ProcessEventJob.perform_later(event)
end

# Consumer runs in background
# Your application continues

# Later, to stop:
thread.kill
```

#### 3. Consumer with Handler Object

```ruby
class EventHandler
  def call(event, subject, deliveries)
    logger.info "Processing #{event['event_type']} from #{subject} (attempt #{deliveries})"
    # Your logic here
  end
end

handler = EventHandler.new
consumer = JetstreamBridge.subscribe(handler)
consumer.run!
```

#### 4. Consumer with Custom Configuration

```ruby
consumer = JetstreamBridge.subscribe(
  durable_name: "my-custom-consumer",
  batch_size: 10
) do |event, subject, deliveries|
  # Process events in batches of 10
end

consumer.run!
```

### Using Consumer Instances Directly

For more control over the consumer lifecycle:

```ruby
consumer = JetstreamBridge::Consumer.new do |event, subject, deliveries|
  # event: parsed envelope
  # subject: NATS subject
  # deliveries: number of delivery attempts

  logger.info "Processing #{event['event_type']} (attempt #{deliveries})"

  begin
    process_event(event)
  rescue RecoverableError => e
    # Let JetStream retry with backoff
    raise
  rescue UnrecoverableError => e
    # Log and acknowledge to prevent infinite retries
    logger.error "Unrecoverable error: #{e.message}"
    # Automatically moved to DLQ if configured
  end
end

consumer.run! # Start processing
```

### Understanding Handler Parameters

Your handler receives three parameters:

```ruby
JetstreamBridge.subscribe do |event, subject, deliveries|
  # event: Hash - the parsed event envelope with payload, event_type, etc.
  # subject: String - the NATS subject the message was published to
  # deliveries: Integer - the delivery attempt number (starts at 1)

  puts "Event type: #{event['event_type']}"
  puts "Subject: #{subject}"
  puts "Delivery attempt: #{deliveries}"

  # Implement retry logic based on deliveries if needed
  raise "Transient error, retry" if deliveries < 3 && some_transient_condition?
end
```

### Consumer Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `handler` | Proc/Callable | (required) | Block or object that responds to `call` |
| `run` | Boolean | `false` | Start consumer in background thread |
| `durable_name` | String | From config | Custom durable consumer name |
| `batch_size` | Integer | From config | Number of messages to fetch at once |

### Inbox Behavior

If **Inbox** is enabled (`config.use_inbox = true`):

* ✅ Deduplicates by `event_id` (or stream sequence as fallback)
* ✅ Records processing state, errors, and timestamps
* ✅ Skips already-processed messages automatically
* ✅ Provides processing history and audit trail
* ✅ Safe across restarts and redeliveries

```ruby
# With inbox enabled, this is automatically idempotent:
JetstreamBridge.subscribe do |event, subject, deliveries|
  # Even if message is redelivered, it won't execute twice
  User.create!(email: event["payload"]["email"])
end
```

### Real-World Examples

#### Processing in Rake Task

```ruby
# lib/tasks/consume_events.rake
namespace :jetstream do
  desc "Start event consumer"
  task consume: :environment do
    consumer = JetstreamBridge.subscribe do |event, subject, deliveries|
      Rails.logger.info "Processing #{event['event_type']} (attempt #{deliveries})"

      case event["resource_type"]
      when "user"
        UserEventHandler.process(event)
      when "order"
        OrderEventHandler.process(event)
      else
        Rails.logger.warn "Unknown resource type: #{event['resource_type']}"
      end
    end

    # Graceful shutdown on SIGTERM
    trap("TERM") { consumer.stop! }

    consumer.run!
  end
end
```

#### Background Job Processing

```ruby
# Offload to background jobs for complex processing
JetstreamBridge.subscribe(run: true) do |event, subject, deliveries|
  ProcessEventJob.perform_later(
    event: event.to_json,
    event_id: event["event_id"],
    trace_id: event["trace_id"]
  )
end

# app/jobs/process_event_job.rb
class ProcessEventJob < ApplicationJob
  queue_as :events

  def perform(event:, event_id:, trace_id:)
    event_data = JSON.parse(event)

    # Complex processing with retries
    case event_data["event_type"]
    when "user.created"
      SendWelcomeEmailService.call(event_data["payload"])
    when "order.completed"
      GenerateInvoiceService.call(event_data["payload"])
    end
  rescue => e
    logger.error "Failed to process event #{event_id}: #{e.message}"
    raise # Let Sidekiq retry
  end
end
```

#### Event Router Pattern

```ruby
# app/services/event_router.rb
class EventRouter
  def self.route(event, subject, deliveries)
    handler_class = "#{event['resource_type'].camelize}#{event['event_type'].camelize}Handler"

    if Object.const_defined?(handler_class)
      handler_class.constantize.new.call(event, subject, deliveries)
    else
      Rails.logger.warn "No handler for #{event['resource_type']}.#{event['event_type']}"
    end
  end
end

# Start consumer with router
JetstreamBridge.subscribe do |event, subject, deliveries|
  EventRouter.route(event, subject, deliveries)
end.run!
```

#### Multi-Service Consumer

```ruby
# app/consumers/application_consumer.rb
class ApplicationConsumer
  def self.start!
    consumer = JetstreamBridge.subscribe do |event, subject, deliveries|
      begin
        new.process(event, subject, deliveries)
      rescue => e
        Rails.logger.error "Error processing event: #{e.message}"
        raise # Trigger retry/DLQ
      end
    end

    # Handle signals gracefully
    %w[INT TERM].each do |signal|
      trap(signal) do
        Rails.logger.info "Shutting down consumer..."
        consumer.stop!
        exit
      end
    end

    Rails.logger.info "Consumer started. Press Ctrl+C to stop."
    consumer.run!
  end

  def process(event, subject, deliveries)
    # Log for observability
    Rails.logger.info(
      message: "Processing event",
      event_id: event["event_id"],
      event_type: event["event_type"],
      resource_type: event["resource_type"],
      trace_id: event["trace_id"],
      subject: subject,
      deliveries: deliveries
    )

    # Route to specific handler
    handler = handler_for(event)
    handler.call(event["payload"], event)
  end

  private

  def handler_for(event)
    case [event["resource_type"], event["event_type"]]
    when ["user", "created"]
      UserCreatedHandler
    when ["user", "updated"]
      UserUpdatedHandler
    when ["order", "completed"]
      OrderCompletedHandler
    else
      UnknownEventHandler
    end
  end
end
```

#### Dockerized Consumer

```dockerfile
# Dockerfile.consumer
FROM ruby:3.2

WORKDIR /app
COPY . .
RUN bundle install

CMD ["bundle", "exec", "rake", "jetstream:consume"]
```

```yaml
# docker-compose.yml
services:
  consumer:
    build:
      context: .
      dockerfile: Dockerfile.consumer
    environment:
      - NATS_URLS=nats://nats:4222
      - RAILS_ENV=production
    depends_on:
      - nats
    restart: unless-stopped
```

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
**`{env}.sync.dlq`**

You may run a separate process to subscribe and triage messages that exceed `max_deliver` or are NAK'ed to the DLQ.

---

## 🛠 Operations Guide

### Monitoring

* **Consumer lag**: `nats consumer info <stream> <durable>`
* **DLQ volume**: subscribe/metrics on `{env}.sync.dlq`
* **Outbox backlog**: alert on `jetstream_outbox_events` with `status != 'sent'` and growing count

### Scaling

* Run consumers in **separate processes/containers**
* Scale consumers independently of web
* Tune `batch_size`, `ack_wait`, `max_deliver`, and `backoff`

### Health Checks

The gem provides built-in health check functionality for monitoring:

```ruby
# Get comprehensive health status
health = JetstreamBridge.health_check
# => {
#   healthy: true,
#   nats_connected: true,
#   connected_at: "2025-11-22T20:00:00Z",
#   stream: { exists: true, name: "...", ... },
#   config: { env: "production", ... },
#   version: "3.0.0"
# }

# Force-connect & ensure topology at boot or in a check
JetstreamBridge.ensure_topology!

# Debug helper for troubleshooting
JetstreamBridge::DebugHelper.debug_info
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

## 🤝 Contributing

We welcome contributions from the community! Here's how you can help:

### Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:

   ```bash
   git clone https://github.com/YOUR_USERNAME/jetstream_bridge.git
   cd jetstream_bridge
   ```

3. **Install dependencies**:

   ```bash
   bundle install
   ```

4. **Set up NATS** for testing (requires Docker):

   ```bash
   docker run -d -p 4222:4222 nats:latest -js
   ```

### Development Workflow

1. **Create a feature branch**:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** with tests:
   * Write meaningful commit messages
   * Add tests for new functionality
   * Update documentation as needed

3. **Run the test suite**:

   ```bash
   bundle exec rspec
   ```

4. **Check code quality**:

   ```bash
   bundle exec rubocop
   ```

5. **Push to your fork** and submit a pull request

### Code Quality Standards

* **Test Coverage**: Maintain >80% line coverage and >70% branch coverage
* **RuboCop**: All code must pass RuboCop checks with zero offenses
* **Tests**: All tests must pass before merging
* **Documentation**: Update README and inline docs for new features

### Pull Request Guidelines

* **Title**: Use clear, descriptive titles (e.g., "Add health check endpoint generator")
* **Description**: Explain what changes were made and why
* **Tests**: Include tests for bug fixes and new features
* **Documentation**: Update relevant documentation
* **One feature per PR**: Keep pull requests focused and reviewable

### Reporting Issues

When reporting bugs, please include:

* **Ruby version**: Output of `ruby -v`
* **Gem version**: Output of `bundle show jetstream_bridge`
* **NATS version**: Version of NATS server
* **Steps to reproduce**: Minimal example that reproduces the issue
* **Expected behavior**: What you expected to happen
* **Actual behavior**: What actually happened
* **Logs/errors**: Relevant error messages or stack traces

### Feature Requests

We love hearing your ideas! When proposing features:

* Search existing issues to avoid duplicates
* Describe the problem you're trying to solve
* Explain your proposed solution
* Consider backwards compatibility

## 🏗️ Development

### Running Tests

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/publisher/publisher_spec.rb

# Run with coverage report
COVERAGE=true bundle exec rspec
```

### Code Coverage

Coverage reports are generated automatically and saved to `coverage/`. View the HTML report:

```bash
open coverage/index.html
```

### Linting

```bash
# Run RuboCop
bundle exec rubocop

# Auto-fix violations
bundle exec rubocop -A
```

### Local Testing with Rails

To test the gem in a Rails application:

1. Point your Gemfile to the local path:

   ```ruby
   gem "jetstream_bridge", path: "../jetstream_bridge"
   ```

2. Run bundle:

   ```bash
   bundle install
   ```

## 📋 Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to the project maintainers.

### Our Standards

* **Be respectful**: Treat everyone with respect and consideration
* **Be inclusive**: Welcome diverse perspectives and experiences
* **Be collaborative**: Work together constructively
* **Be professional**: Keep discussions focused and constructive

## 🌟 Community

* **Discussions**: Use GitHub Discussions for questions and ideas
* **Issues**: Report bugs and request features via GitHub Issues
* **Pull Requests**: Submit improvements via pull requests

## 🙏 Acknowledgments

Built with:

* [NATS.io](https://nats.io) - High-performance messaging system
* [nats-pure.rb](https://github.com/nats-io/nats-pure.rb) - Ruby client for NATS

## 📊 Project Status

* **CI/CD**: Automated testing and code quality checks
* **Code Coverage**: 85%+ maintained
* **Active Development**: Regular updates and maintenance
* **Semantic Versioning**: Follows [SemVer](https://semver.org/)

## 📄 License

[MIT License](LICENSE) - Copyright (c) 2025 Mike Attara
