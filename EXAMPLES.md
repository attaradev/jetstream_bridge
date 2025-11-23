# JetStream Bridge - Usage Examples

## Table of Contents
- [Basic Publishing](#basic-publishing)
- [Advanced Publishing](#advanced-publishing)
- [Batch Publishing](#batch-publishing)
- [Consumer Patterns](#consumer-patterns)
- [Error Handling](#error-handling)
- [Configuration](#configuration)
- [Model Queries](#model-queries)
- [Testing](#testing)

## Basic Publishing

### Simple Event Publishing
```ruby
# Publish a simple event
result = JetstreamBridge.publish(
  event_type: "user.created",
  payload: { id: 1, email: "user@example.com" }
)

if result.success?
  puts "Published event #{result.event_id}"
else
  puts "Failed: #{result.error.message}"
end
```

### Publishing with Metadata
```ruby
# Include trace_id for distributed tracing
result = JetstreamBridge.publish(
  event_type: "order.completed",
  payload: {
    order_id: order.id,
    total: order.total,
    items: order.items.count
  },
  trace_id: Current.request_id,
  occurred_at: order.completed_at
)
```

### Publishing from ActiveRecord Callbacks
```ruby
class User < ApplicationRecord
  after_commit :publish_created_event, on: :create

  private

  def publish_created_event
    result = JetstreamBridge.publish(
      event_type: "user.created",
      payload: {
        id: id,
        email: email,
        name: name,
        created_at: created_at
      }
    )

    unless result.success?
      Rails.logger.error("Failed to publish user.created: #{result.error}")
    end
  end
end
```

## Advanced Publishing

### With Transactional Outbox
```ruby
# Ensure event is published even if NATS is down
ActiveRecord::Base.transaction do
  user = User.create!(user_params)

  # Saved to outbox table first, then published
  JetstreamBridge.publish(
    event_type: "user.created",
    payload: { id: user.id, email: user.email }
  )
end
# Both user creation and event publishing succeed or fail together
```

### Custom Resource Type
```ruby
# Explicitly specify resource type
JetstreamBridge.publish(
  resource_type: "customer",
  event_type: "registered",
  payload: customer.attributes
)
```

### Handling Duplicates
```ruby
result = JetstreamBridge.publish(
  event_type: "payment.processed",
  event_id: payment.transaction_id, # Use payment ID as event ID
  payload: payment.attributes
)

if result.duplicate?
  Rails.logger.info("Duplicate publish detected (idempotent)")
end
```

## Batch Publishing

### Publishing Multiple Events Efficiently
```ruby
# Batch publish with automatic retry on partial failures
results = JetstreamBridge.publish_batch do |batch|
  users.find_each do |user|
    batch.add(
      event_type: "user.migrated",
      payload: { id: user.id, email: user.email }
    )
  end
end

puts "Published #{results.successful_count} events"
puts "Failed #{results.failed_count} events"

# Handle failures
if results.failure?
  results.errors.each do |error|
    Rails.logger.error("Failed #{error[:event_id]}: #{error[:error]}")
  end
end
```

### Batch with Mixed Event Types
```ruby
JetstreamBridge.publish_batch do |batch|
  # Add different event types to same batch
  batch.add(event_type: "user.created", payload: { id: 1 })
  batch.add(event_type: "user.updated", payload: { id: 2 })
  batch.add(event_type: "order.created", payload: { id: 100 })
end
```

## Consumer Patterns

### Basic Consumer
```ruby
# Simple event handler
consumer = JetstreamBridge.subscribe do |event|
  puts "Received: #{event.type}"
  puts "Payload: #{event.payload.to_h}"
  puts "Delivery attempt: #{event.deliveries}"

  # Your business logic here
  process_event(event)
end

consumer.run! # Start consuming (blocks)
```

### Consumer with Type Routing
```ruby
consumer = JetstreamBridge.subscribe do |event|
  case event.type
  when "user.created"
    UserCreatedHandler.call(event.payload)
  when "user.updated"
    UserUpdatedHandler.call(event.payload)
  when "user.deleted"
    UserDeletedHandler.call(event.payload)
  else
    Rails.logger.warn("Unknown event type: #{event.type}")
  end
end

consumer.run!
```

### Consumer in Rake Task
```ruby
# lib/tasks/consume_events.rake
namespace :jetstream do
  desc "Start JetStream consumer"
  task consume: :environment do
    consumer = JetstreamBridge.subscribe do |event|
      Rails.logger.info("Processing #{event.type} (attempt #{event.deliveries})")

      EventProcessor.process(event)
    rescue StandardError => e
      Rails.logger.error("Failed to process #{event.event_id}: #{e.message}")
      raise # Let JetStream handle retry
    end

    # Graceful shutdown
    trap("TERM") do
      Rails.logger.info("Shutting down consumer...")
      consumer.stop!
    end

    consumer.run!
  end
end
```

### Consumer with Custom Handler Class
```ruby
class EventHandler
  def call(event)
    # Access event properties with methods
    user_id = event.payload.user_id
    event_type = event.type
    trace_id = event.metadata.trace_id

    # Your logic
    User.find(user_id).process_event(event_type)
  end
end

handler = EventHandler.new
consumer = JetstreamBridge.subscribe(handler)
consumer.run!
```

### Async Consumer
```ruby
# Run consumer in background thread
thread = JetstreamBridge.subscribe(run: true) do |event|
  # Process in background
  ProcessEventJob.perform_later(event.to_h)
end

# Your app continues running
# ...

# Later, to stop
thread.kill
```

## Error Handling

### Handling Publish Errors
```ruby
begin
  result = JetstreamBridge.publish(
    event_type: "critical.event",
    payload: data
  )

  raise result.error if result.failure?

rescue JetstreamBridge::PublishError => e
  # Rich error context available
  Sentry.capture_exception(e, extra: {
    event_id: e.event_id,
    subject: e.subject,
    context: e.context
  })

  # Take corrective action
  backup_to_disk(data, e)
end
```

### Consumer Error Handling
```ruby
consumer = JetstreamBridge.subscribe do |event|
  begin
    process_event(event)
  rescue RecoverableError => e
    # Log and let JetStream retry with backoff
    Rails.logger.warn("Recoverable error on #{event.event_id}: #{e}")
    raise
  rescue UnrecoverableError => e
    # Log and don't retry (goes to DLQ if configured)
    Rails.logger.error("Unrecoverable error on #{event.event_id}: #{e}")
    # Don't raise - ACK the message to prevent infinite retries
  end
end
```

### Retry Logic Based on Delivery Count
```ruby
consumer = JetstreamBridge.subscribe do |event|
  if event.deliveries > 3
    # Last attempt - try alternative processing
    fallback_process(event)
  else
    # Normal processing
    standard_process(event)
  end
rescue StandardError => e
  # Different handling based on attempt count
  if event.deliveries >= JetstreamBridge.config.max_deliver
    notify_ops_team("Max retries exceeded for #{event.event_id}")
  end
  raise
end
```

## Configuration

### Environment-Specific Configuration
```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # Basic settings
  config.nats_urls = ENV.fetch("NATS_URLS")
  config.app_name = ENV.fetch("APP_NAME", "my_app")
  config.destination_app = ENV.fetch("DESTINATION_APP")
  config.env = Rails.env

  # Apply preset based on environment
  case Rails.env
  when "production"
    config.apply_preset(:production)
  when "staging"
    config.apply_preset(:staging)
  when "development"
    config.apply_preset(:development)
  when "test"
    config.apply_preset(:test)
  end

  # Environment-specific overrides
  if Rails.env.production?
    config.max_deliver = 10
    config.logger = Rails.logger
  end
end
```

### Custom Configuration
```ruby
JetstreamBridge.configure do |config|
  # Start with a preset
  config.apply_preset(:production)

  # Customize as needed
  config.max_deliver = 7
  config.ack_wait = "45s"
  config.backoff = %w[2s 10s 30s 60s 120s 300s 600s]

  # Custom models (if you have your own tables)
  config.outbox_model = "MyApp::OutboxEvent"
  config.inbox_model = "MyApp::InboxEvent"
end
```

### Preset-Based Configuration
```ruby
# Quick setup with preset
JetstreamBridge.configure_for(:production) do |config|
  # All production defaults applied
  # Just set required fields
  config.nats_urls = ENV["NATS_URLS"]
  config.app_name = "my_app"
  config.destination_app = "worker_app"
end
```

## Model Queries

### Managing Outbox Events
```ruby
# Find and retry failed events
failed_events = OutboxEvent.failed.recent(100)
failed_events.each do |event|
  puts "Failed: #{event.event_id} - #{event.last_error}"
end

# Bulk retry
OutboxEvent.retry_failed(limit: 50)

# Find stale events (pending > 1 hour)
stale = OutboxEvent.stale
stale.each do |event|
  # Investigate or retry
  event.retry!
end

# Cleanup old sent events
deleted_count = OutboxEvent.cleanup_sent(older_than: 7.days)
puts "Cleaned up #{deleted_count} old events"

# Query by resource type
user_events = OutboxEvent.by_resource_type("user").pending
order_events = OutboxEvent.by_resource_type("order").failed
```

### Managing Inbox Events
```ruby
# Check processing statistics
stats = InboxEvent.processing_stats
puts "Total: #{stats[:total]}"
puts "Processed: #{stats[:processed]}"
puts "Failed: #{stats[:failed]}"
puts "Pending: #{stats[:pending]}"

# Find unprocessed events
unprocessed = InboxEvent.unprocessed.recent(50)

# Query by subject
subject_events = InboxEvent.by_subject("production.api.sync.worker")

# Cleanup old processed events
deleted = InboxEvent.cleanup_processed(older_than: 30.days)
puts "Cleaned up #{deleted} processed events"

# Manually mark as processed
event = InboxEvent.find_by(event_id: "some-id")
event.mark_processed!

# Mark as failed
event.mark_failed!("Processing error: #{error.message}")
```

### Custom Queries
```ruby
# Complex query combining scopes
OutboxEvent
  .failed
  .by_resource_type("user")
  .where("attempts < ?", 3)
  .recent(100)
  .find_each do |event|
    # Retry with custom logic
    event.retry! if should_retry?(event)
  end

# Find events for specific trace
InboxEvent
  .where("headers->>'trace_id' = ?", trace_id)
  .order(received_at: :asc)
```

## Testing

### RSpec with Test Helpers
```ruby
# spec/support/jetstream_bridge.rb
require 'jetstream_bridge/test_helpers'

RSpec.configure do |config|
  config.include JetstreamBridge::TestHelpers

  config.before(:each, :jetstream) do
    JetstreamBridge.enable_test_mode!
  end

  config.after(:each, :jetstream) do
    JetstreamBridge.reset_test_mode!
  end
end

# In your specs
RSpec.describe UserService, :jetstream do
  it "publishes user created event" do
    service.create_user(name: "Ada")

    expect(JetstreamBridge).to have_published(
      event_type: "user.created",
      payload: hash_including(name: "Ada")
    )
  end
end
```

### Testing Event Processing
```ruby
RSpec.describe UserEventHandler do
  it "processes user.created events" do
    event = build_jetstream_event(
      event_type: "user.created",
      payload: { id: 1, email: "user@example.com" }
    )

    expect {
      described_class.call(event)
    }.to change(User, :count).by(1)
  end
end
```

### Mocking in Tests
```ruby
# Mock the publish method
RSpec.describe OrderController do
  it "publishes order completed event" do
    allow(JetstreamBridge).to receive(:publish).and_return(
      JetstreamBridge::Models::PublishResult.new(
        success: true,
        event_id: "test-123",
        subject: "test.subject"
      )
    )

    post :complete, params: { id: order.id }

    expect(JetstreamBridge).to have_received(:publish).with(
      event_type: "order.completed",
      payload: hash_including(order_id: order.id)
    )
  end
end
```

## Advanced Patterns

### Event Sourcing
```ruby
class User < ApplicationRecord
  after_commit :publish_event, on: [:create, :update, :destroy]

  private

  def publish_event
    event_type = case transaction_include_any_action?([:create])
                 when true then "created"
                 when false then saved_changes.any? ? "updated" : "deleted"
                 end

    JetstreamBridge.publish(
      resource_type: "user",
      event_type: event_type,
      payload: attributes
    )
  end
end
```

### Saga Pattern
```ruby
# Orchestrator
class OrderSaga
  def call(order)
    # Publish order created
    JetstreamBridge.publish(
      event_type: "order.created",
      payload: { order_id: order.id, total: order.total }
    )

    # Listen for responses
    consumer = JetstreamBridge.subscribe do |event|
      case event.type
      when "payment.processed"
        handle_payment_success(event)
      when "payment.failed"
        handle_payment_failure(event)
      end
    end
  end
end
```

### CQRS Pattern
```ruby
# Write side
class CreateUserCommand
  def call(params)
    user = User.create!(params)

    # Publish event for read side
    JetstreamBridge.publish(
      event_type: "user.created",
      payload: user.attributes
    )

    user
  end
end

# Read side (consumer)
consumer = JetstreamBridge.subscribe do |event|
  case event.type
  when "user.created"
    UserReadModel.create!(event.payload.to_h)
  when "user.updated"
    UserReadModel.find(event.payload.id).update!(event.payload.to_h)
  end
end
```

---

For more information, see:
- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Implementation details
- [API_IMPROVEMENTS_SUMMARY.md](API_IMPROVEMENTS_SUMMARY.md) - Feature summary
- [README.md](README.md) - Full documentation
