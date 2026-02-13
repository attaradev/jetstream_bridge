# API Reference

Complete reference for JetstreamBridge public API.

## Table of Contents

- [Configuration](#configuration)
- [Lifecycle Methods](#lifecycle-methods)
- [Publishing](#publishing)
- [Consuming](#consuming)
- [Provisioning](#provisioning)
- [Health & Diagnostics](#health--diagnostics)
- [Models](#models)

## Configuration

### `JetstreamBridge.configure`

Configure the library. Must be called before connecting.

```ruby
JetstreamBridge.configure do |config|
  # Required
  config.app_name        = "my_app"
  config.destination_app = "other_app"

  # Connection
  config.nats_urls = "nats://localhost:4222"  # or array of URLs
  config.stream_name = "jetstream-bridge-stream"

  # Features
  config.use_outbox = true   # Transactional publish (requires ActiveRecord)
  config.use_inbox  = true   # Idempotent consume (requires ActiveRecord)
  config.use_dlq    = true   # Dead letter queue for poison messages

  # Consumer settings
  config.max_deliver  = 5     # Max delivery attempts
  config.ack_wait     = "30s" # Time to wait for ACK
  config.backoff      = ["1s", "5s", "15s", "30s", "60s"]

  # Provisioning
  config.auto_provision = true  # Auto-create stream on startup (consumers are always auto-created)

  # Connection behavior
  config.lazy_connect = false  # Set true to skip autostart
  config.connect_retry_attempts = 3
  config.connect_retry_delay = 1  # seconds
end
```

### `JetstreamBridge.config`

Returns the current configuration object, creating a default instance if needed.

```ruby
stream_name = JetstreamBridge.config.stream_name
```

## Lifecycle Methods

### `JetstreamBridge.startup!`

Explicitly start the connection and provision topology (if `auto_provision=true`).

```ruby
JetstreamBridge.startup!
```

**Raises:** `ConfigurationError`, `ConnectionError`

**Note:** Rails applications auto-start after initialization. Non-Rails apps should call this manually or rely on auto-connect on first publish/subscribe.

### `JetstreamBridge.shutdown!`

Gracefully close the NATS connection.

```ruby
JetstreamBridge.shutdown!
```

### `JetstreamBridge.reset!`

Reset all internal state (for testing). Also resets consumer signal handlers.

```ruby
JetstreamBridge.reset!
```

## Publishing

### `JetstreamBridge.publish`

Publish an event to the destination app.

```ruby
JetstreamBridge.publish(
  event_type: "user.created",     # Required
  resource_type: "user",          # Required
  payload: { id: user.id, email: user.email },
  event_id: "custom-uuid"         # Optional (auto-generated)
)
```

**Returns:** `Models::PublishResult`

**With Outbox:**

```ruby
# Transactional publish (commits with your DB transaction)
User.transaction do
  user.save!
  JetstreamBridge.publish(event_type: "user.created", resource_type: "user", payload: user)
end
```

### `JetstreamBridge.publish!`

Like `publish` but raises on error.

```ruby
JetstreamBridge.publish!(event_type: "user.created", resource_type: "user", payload: data)
```

**Raises:** `JetstreamBridge::PublishError` on failure

### `JetstreamBridge.publish_batch`

Publish multiple events efficiently.

```ruby
results = JetstreamBridge.publish_batch do |batch|
  users.each do |user|
    batch.add(event_type: "user.created", resource_type: "user", payload: user)
  end
end

puts "Published: #{results.successful_count}, Failed: #{results.failed_count}"
```

## Consuming

### `JetstreamBridge::Consumer.new`

Create a consumer to process incoming events.

```ruby
consumer = JetstreamBridge::Consumer.new do |event|
  # Process event
  User.upsert({ id: event.payload["id"], email: event.payload["email"] })
end
```

**Options:**

```ruby
consumer = JetstreamBridge::Consumer.new(
  durable_name: "my-consumer",  # Override default durable name
  batch_size: 10                # Process up to 10 messages at once
) do |event|
  # ...
end
```

### `Consumer#run!`

Start consuming messages (blocks until interrupted).

```ruby
consumer.run!
```

### `Consumer#stop!`

Gracefully stop the consumer.

```ruby
consumer.stop!
```

### Event Object

The event object passed to your handler:

```ruby
event.event_id       # => "evt_123"
event.type           # => "user.created"
event.resource_type  # => "user"
event.resource_id    # => "456"
event.payload        # => PayloadAccessor (supports method-style: event.payload.email)
event.subject        # => "source_app.sync.my_app"
event.stream         # => "jetstream-bridge-stream"
event.sequence       # => 123
event.deliveries     # => 1
```

## Provisioning

### `JetstreamBridge.provision!`

Manually provision stream and consumer.

```ruby
# Provision both stream and consumer
JetstreamBridge.provision!

# Provision stream only
JetstreamBridge.provision!(provision_consumer: false)
```

### `JetstreamBridge::Provisioner`

Dedicated provisioning class for advanced use cases.

```ruby
provisioner = JetstreamBridge::Provisioner.new

# Provision everything
provisioner.provision!

# Or separately
provisioner.provision_stream!
provisioner.provision_consumer!
```

### `JetstreamBridge::SubscriptionManager`

Manages consumer lifecycle during subscription. Used internally by `Consumer`, but also available for advanced use cases.

```ruby
# Create subscription manager
sub_mgr = JetstreamBridge::SubscriptionManager.new(jetstream_context, "my-durable")

# Check if stream exists
sub_mgr.stream_exists?  # => true/false

# Check if consumer exists
sub_mgr.consumer_exists?  # => true/false

# Create consumer if missing (raises StreamNotFoundError if stream doesn't exist)
sub_mgr.create_consumer_if_missing!
```

**Note:** Consumers are automatically created when subscribing, regardless of the `auto_provision` setting. The `auto_provision` setting only controls stream topology creation.

**Raises:** `JetstreamBridge::StreamNotFoundError` if the stream doesn't exist when calling `create_consumer_if_missing!`

## Health & Diagnostics

### `JetstreamBridge.health_check`

Get comprehensive health status.

```ruby
health = JetstreamBridge.health_check

health[:healthy]                            # => true/false
health[:connection][:state]                 # => :connected
health[:connection][:connected]             # => true/false
health[:connection][:connected_at]          # => "2025-01-01T00:00:00Z"
health[:stream][:exists]                    # => true/false
health[:stream][:name]                      # => "jetstream-bridge-stream"
health[:stream][:subjects]                  # => ["app.sync.worker"]
health[:stream][:messages]                  # => 123
health[:performance][:nats_rtt_ms]          # => 1.2
health[:performance][:health_check_duration_ms] # => 45.2
health[:config]                             # => { app_name:, stream_name:, ... }
health[:version]                            # => "7.0.0"
```

### `JetstreamBridge.stream_info`

Get detailed stream information.

```ruby
info = JetstreamBridge.stream_info

info[:name]               # => "jetstream-bridge-stream"
info[:subjects]           # => ["app1.sync.app2", ...]
info[:messages]           # => 1000
info[:bytes]              # => 204800
info[:first_seq]          # => 1
info[:last_seq]           # => 1000
info[:consumer_count]     # => 2
```

## Models

### `JetstreamBridge::OutboxEvent`

ActiveRecord model for outbox events (when `use_outbox=true`).

```ruby
# Create outbox event
event = JetstreamBridge::OutboxEvent.create!(
  event_id: SecureRandom.uuid,
  event_type: "user.created",
  resource_type: "user",
  resource_id: "123",
  payload: { id: 123, email: "user@example.com" },
  subject: "my_app.sync.other_app",
  status: "pending"
)

# Query
JetstreamBridge::OutboxEvent.pending.limit(100)
JetstreamBridge::OutboxEvent.failed

# Mark as published
event.mark_published!

# Cleanup old events
JetstreamBridge::OutboxEvent.cleanup_published(older_than: 7.days)
```

### `JetstreamBridge::InboxEvent`

ActiveRecord model for inbox events (when `use_inbox=true`).

```ruby
# Find by event_id
event = JetstreamBridge::InboxEvent.find_by(event_id: "evt_123")

# Query
JetstreamBridge::InboxEvent.received
JetstreamBridge::InboxEvent.processing
JetstreamBridge::InboxEvent.processed
JetstreamBridge::InboxEvent.failed
JetstreamBridge::InboxEvent.recent(100)

# Mark as processed
event.mark_processed!

# Mark as failed
event.mark_failed!("Error message")

# Cleanup old events
JetstreamBridge::InboxEvent.cleanup_processed(older_than: 30.days)

# Statistics
stats = JetstreamBridge::InboxEvent.processing_stats
stats[:total]       # => 1000
stats[:processed]   # => 950
stats[:failed]      # => 30
stats[:pending]     # => 20
```

## Error Handling

### `JetstreamBridge::PublishError`

Raised by `publish!` when publishing fails.

```ruby
begin
  JetstreamBridge.publish!(event_type: "test", resource_type: "test", payload: {})
rescue JetstreamBridge::PublishError => e
  logger.error("Publish failed: #{e.message}")
  logger.error("Event ID: #{e.event_id}")
  logger.error("Subject: #{e.subject}")
end
```

### `JetstreamBridge::StreamNotFoundError`

Raised when attempting to create a consumer on a stream that doesn't exist.

```ruby
begin
  consumer = JetstreamBridge::Consumer.new { |event| process(event) }
  consumer.run!
rescue JetstreamBridge::StreamNotFoundError => e
  logger.error("Stream not found: #{e.message}")
  # Stream must be provisioned separately (use auto_provision=true or run provisioning with admin credentials)
end
```

### Custom Error Handling (Middleware)

```ruby
class SentryErrorMiddleware
  def call(event)
    yield
  rescue StandardError => e
    logger.error("Failed to process event #{event.event_id}: #{e.message}")
    Sentry.capture_exception(e, extra: { event_id: event.event_id })
    raise  # Re-raise so the consumer can NAK/DLQ as appropriate
  end
end

consumer = JetstreamBridge::Consumer.new do |event|
  # Process event
end
consumer.use(SentryErrorMiddleware.new)
```

## Testing

### Test Mode

Enable mock NATS for testing without infrastructure.

```ruby
# RSpec
RSpec.configure do |config|
  config.before(:each, :jetstream) do
    JetstreamBridge::TestHelpers.enable_test_mode!
  end

  config.after(:each, :jetstream) do
    JetstreamBridge::TestHelpers.reset_test_mode!
  end
end

# Test
it "publishes events", :jetstream do
  result = JetstreamBridge.publish(event_type: "test", resource_type: "test", payload: {})
  expect(result).to be_success
end
```

See [TESTING.md](TESTING.md) for comprehensive testing documentation.

## See Also

- [Getting Started](GETTING_STARTED.md) - Setup and basic usage
- [Architecture](ARCHITECTURE.md) - Internal architecture and patterns
- [Production Guide](PRODUCTION.md) - Production deployment
- [Testing Guide](TESTING.md) - Testing with Mock NATS
