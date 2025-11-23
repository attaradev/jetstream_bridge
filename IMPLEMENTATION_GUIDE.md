# JetStream Bridge API Improvements - Implementation Guide

This document outlines the comprehensive API improvements implemented and those pending completion.

## ✅ Completed Implementations

### 1. New Models and Value Objects

#### Created Files

- `lib/jetstream_bridge/models/publish_result.rb` - Result object for publish operations
- `lib/jetstream_bridge/models/event.rb` - Structured event object for consumers
- `lib/jetstream_bridge/models/subject.rb` - Enhanced with parsing and metadata methods
- `lib/jetstream_bridge/publisher/batch_publisher.rb` - Batch publishing support
- `lib/jetstream_bridge/core/config_preset.rb` - Configuration presets

#### Key Features

```ruby
# PublishResult - replaces boolean returns
result = JetstreamBridge.publish(event_type: "user.created", payload: {id: 1})
result.success?      # => true
result.event_id      # => "uuid"
result.duplicate?    # => false
result.error         # => nil or Exception

# Event - structured object for consumers
JetstreamBridge.subscribe do |event|
  event.type              # "user.created"
  event.payload.user_id   # Method-style access
  event.deliveries        # 1
  event.metadata.trace_id # "abc123"
end

# BatchPublisher
JetstreamBridge.publish_batch do |batch|
  batch.add(event_type: "user.created", payload: {id: 1})
  batch.add(event_type: "user.created", payload: {id: 2})
end
```

### 2. Enhanced Error Handling

#### Updated: `lib/jetstream_bridge/errors.rb`

All errors now support context:

```ruby
raise PublishError.new(
  "Failed to publish",
  event_id: "123",
  subject: "prod.api.sync.worker",
  context: { retry_attempt: 3 }
)

# Access context
rescue PublishError => e
  e.event_id   # "123"
  e.subject    # "prod.api.sync.worker"
  e.context    # { event_id: "123", subject: "prod.api.sync.worker", retry_attempt: 3 }
end
```

### 3. Configuration Presets

#### Created: `lib/jetstream_bridge/core/config_preset.rb`

```ruby
# Quick configuration for common scenarios
JetstreamBridge.configure do |config|
  config.apply_preset(:production)
  # Customization after preset
  config.max_deliver = 10
end

# Available presets:
# - :development (minimal features, fast)
# - :test (synchronous, fast retries)
# - :production (all reliability features)
# - :staging (production-like, faster retries)
# - :high_throughput (optimized for volume)
# - :maximum_reliability (every safety feature)
```

### 4. Model Enhancements

#### Updated: `lib/jetstream_bridge/models/outbox_event.rb`

#### Updated: `lib/jetstream_bridge/models/inbox_event.rb`

Added query scopes and helper methods:

```ruby
# OutboxEvent scopes
OutboxEvent.pending
OutboxEvent.failed
OutboxEvent.stale           # pending older than 1 hour
OutboxEvent.by_resource_type("user")
OutboxEvent.recent(100)

# Helper methods
OutboxEvent.retry_failed(limit: 100)
OutboxEvent.cleanup_sent(older_than: 7.days)
event.retry!

# InboxEvent scopes
InboxEvent.processed
InboxEvent.unprocessed
InboxEvent.by_subject("prod.api.sync.worker")
InboxEvent.recent(50)

# Helper methods
InboxEvent.cleanup_processed(older_than: 30.days)
InboxEvent.processing_stats
event.mark_processed!
event.mark_failed!("Error message")
```

### 5. Status Constants

#### Updated: `lib/jetstream_bridge/core/config.rb`

Added Status module with constants:

```ruby
JetstreamBridge::Config::Status::PENDING
JetstreamBridge::Config::Status::PUBLISHING
JetstreamBridge::Config::Status::SENT
JetstreamBridge::Config::Status::FAILED
JetstreamBridge::Config::Status::RECEIVED
JetstreamBridge::Config::Status::PROCESSING
JetstreamBridge::Config::Status::PROCESSED
```

## 🚧 Pending Implementations

### 1. Update Publisher to Return PublishResult

**File**: `lib/jetstream_bridge/publisher/publisher.rb`

**Changes Needed**:

```ruby
# Add require at top
require_relative '../models/publish_result'

# Update publish method to return PublishResult instead of Boolean
def publish(...)
  # ... existing code ...
  result = do_publish(resolved_subject, envelope)

  # Return PublishResult object
  Models::PublishResult.new(
    success: result,
    event_id: envelope['event_id'],
    subject: resolved_subject,
    duplicate: false # Get from NATS ack if available
  )
rescue StandardError => e
  Models::PublishResult.new(
    success: false,
    event_id: envelope&.[]('event_id') || 'unknown',
    subject: resolved_subject || 'unknown',
    error: e
  )
end

# Update publish_to_nats to track duplicate status
def publish_to_nats(subject, envelope)
  # ... existing code ...
  { success: true, duplicate: duplicate }
end
```

### 2. Update Consumer to Use Event Object

**File**: `lib/jetstream_bridge/consumer/message_processor.rb`

**Changes Needed**:

```ruby
# Add require
require_relative '../models/event'

# Update process_event method
def process_event(msg, event_hash, ctx)
  # Convert hash to Event object
  event = Models::Event.new(
    event_hash,
    metadata: {
      subject: ctx.subject,
      deliveries: ctx.deliveries,
      stream: ctx.stream,
      sequence: ctx.seq,
      consumer: ctx.consumer
    }
  )

  # Call handler with Event object
  # For backwards compatibility, check arity
  if @handler.arity == 1
    @handler.call(event)
  else
    # Legacy: pass hash, subject, deliveries
    @handler.call(event_hash, ctx.subject, ctx.deliveries)
  end

  msg.ack
  # ... rest of method
end
```

### 3. Add Middleware Pattern for Consumers

**Create**: `lib/jetstream_bridge/consumer/middleware.rb`

```ruby
module JetstreamBridge
  module Consumer
    # Middleware chain for consumer message processing
    class MiddlewareChain
      def initialize
        @middlewares = []
      end

      def use(middleware)
        @middlewares << middleware
        self
      end

      def call(event, &final_handler)
        chain = @middlewares.reverse.reduce(final_handler) do |next_middleware, middleware|
          lambda do |evt|
            middleware.call(evt) { next_middleware.call(evt) }
          end
        end
        chain.call(event)
      end
    end

    # Example middleware for logging
    class LoggingMiddleware
      def call(event)
        start = Time.now
        Logging.info("Processing event #{event.event_id}", tag: 'Consumer')
        yield
        duration = Time.now - start
        Logging.info("Completed event #{event.event_id} in #{duration}s", tag: 'Consumer')
      rescue StandardError => e
        Logging.error("Failed event #{event.event_id}: #{e.message}", tag: 'Consumer')
        raise
      end
    end
  end
end
```

### 4. Add Test Helpers

**Create**: `lib/jetstream_bridge/test_helpers.rb`

```ruby
module JetstreamBridge
  module TestHelpers
    # Enable test mode with in-memory transport
    def self.enable_test_mode!
      @test_mode = true
      @published_events = []
    end

    def self.reset_test_mode!
      @test_mode = false
      @published_events = []
    end

    def self.test_mode?
      @test_mode
    end

    def self.published_events
      @published_events ||= []
    end

    # RSpec matchers
    module Matchers
      def have_published(event_type:, **attributes)
        HavePublished.new(event_type, attributes)
      end

      class HavePublished
        def initialize(event_type, attributes)
          @event_type = event_type
          @attributes = attributes
        end

        def matches?(actual)
          TestHelpers.published_events.any? do |event|
            event[:event_type] == @event_type &&
              @attributes.all? { |k, v| event[:payload][k] == v }
          end
        end

        def failure_message
          "expected to have published #{@event_type} with #{@attributes}"
        end
      end
    end

    # Helper methods
    def build_jetstream_event(event_type:, payload:, **options)
      Models::Event.new(
        {
          'event_type' => event_type,
          'event_id' => SecureRandom.uuid,
          'payload' => payload,
          'producer' => 'test',
          'occurred_at' => Time.now.utc.iso8601
        }.merge(options.transform_keys(&:to_s)),
        metadata: {}
      )
    end

    def trigger_jetstream_event(event)
      # Simulate event delivery to consumer
      # Implementation depends on how consumers are structured
    end
  end
end
```

### 5. Update Main Module API

**File**: `lib/jetstream_bridge.rb`

**Changes Needed**:

```ruby
# Add new requires
require_relative 'jetstream_bridge/models/publish_result'
require_relative 'jetstream_bridge/models/event'
require_relative 'jetstream_bridge/publisher/batch_publisher'

module JetstreamBridge
  class << self
    # Add configure_for helper
    def configure_for(preset, &block)
      configure do |config|
        config.apply_preset(preset)
        yield(config) if block_given?
      end
    end

    # Add batch publishing
    def publish_batch(&block)
      batch = BatchPublisher.new
      yield(batch) if block_given?
      batch.publish
    end

    # Update publish to work with new API
    # (Already returns PublishResult after Publisher is updated)

    # Add publish! variant that raises on error
    def publish!(...)
      result = publish(...)
      raise result.error if result.failure?
      result
    end
  end
end
```

### 6. Add YARD Documentation

Add comprehensive YARD docs to all public methods. Example pattern:

```ruby
# Publishes an event to NATS JetStream with guaranteed delivery semantics.
#
# @example Publishing a simple event
#   result = JetstreamBridge.publish(
#     event_type: "user.created",
#     payload: { id: 1, email: "user@example.com" }
#   )
#   puts "Published: #{result.event_id}" if result.success?
#
# @example Publishing with custom metadata
#   JetstreamBridge.publish(
#     event_type: "order.completed",
#     payload: order.attributes,
#     trace_id: request_id,
#     occurred_at: Time.now.utc
#   )
#
# @param event_type [String] The type of event in dot notation (e.g., "user.created")
# @param payload [Hash] The event payload data
# @param resource_type [String, nil] Optional resource type (inferred from event_type if not provided)
# @param event_id [String, nil] Optional custom event ID (auto-generated if not provided)
# @param trace_id [String, nil] Optional trace ID for distributed tracing
# @param occurred_at [Time, String, nil] Optional timestamp (defaults to now)
# @return [Models::PublishResult] Result object with success status and metadata
# @raise [ArgumentError] If required parameters are missing or invalid
# @raise [PublishError] If publishing fails and using publish! variant
#
# @see Models::PublishResult
# @see #publish!
def publish(event_type:, payload:, **options)
  # ...
end
```

## Migration Strategy

### Phase 1: Backwards Compatible (Current State)

- ✅ All new models created
- ✅ Error classes enhanced
- ✅ Model scopes added
- ✅ Config presets added
- Current API still works exactly as before

### Phase 2: Introduce New APIs (Recommended Next Steps)

1. Update Publisher to return PublishResult
2. Add backwards compatibility layer that responds to truthy/falsy
3. Update Consumer to provide Event object
4. Check handler arity for backwards compatibility
5. Add deprecation warnings for old patterns

### Phase 3: Documentation and Examples

1. Add YARD docs to all public methods
2. Create examples/ directory with working samples
3. Update README with new patterns
4. Add migration guide for existing users

### Phase 4: Full Migration (Future Major Version)

1. Remove backwards compatibility layers
2. Make Event object mandatory in consumers
3. Remove boolean-like behavior from PublishResult
4. Update all examples and docs

## Testing Strategy

### New Tests Needed

1. **PublishResult specs** (`spec/models/publish_result_spec.rb`)
2. **Event specs** (`spec/models/event_spec.rb`)
3. **BatchPublisher specs** (`spec/publisher/batch_publisher_spec.rb`)
4. **ConfigPreset specs** (`spec/core/config_preset_spec.rb`)
5. **Model scopes specs** (update existing outbox/inbox specs)
6. **Middleware specs** (`spec/consumer/middleware_spec.rb`)
7. **TestHelpers specs** (`spec/test_helpers_spec.rb`)

### Update Existing Tests

Update all publisher tests to check for PublishResult:

```ruby
# Old
expect(result).to be(true)

# New
expect(result).to be_success
expect(result.event_id).to be_present
```

Update consumer tests to provide Event objects:

```ruby
# Old
handler.call(event_hash, subject, deliveries)

# New
event = JetstreamBridge::Models::Event.new(event_hash, metadata: {...})
handler.call(event)
```

## Benefits Summary

### For Users

- **Better error handling**: Full context in exceptions
- **Type safety**: Structured objects instead of hashes
- **Discoverability**: Method access instead of hash keys
- **Testability**: Test helpers for easy mocking
- **Flexibility**: Middleware for cross-cutting concerns

### For Maintainers

- **Consistency**: Clear patterns throughout
- **Extensibility**: Easy to add new features
- **Documentation**: Self-documenting with YARD
- **Testing**: Comprehensive test coverage

## Rollout Checklist

- [ ] Complete Publisher PublishResult refactor
- [ ] Complete Consumer Event object refactor
- [ ] Add middleware pattern
- [ ] Add test helpers
- [ ] Add comprehensive YARD documentation
- [ ] Create examples directory
- [ ] Update README with new patterns
- [ ] Create UPGRADING.md guide
- [ ] Update CI to run new tests
- [ ] Add deprecation warnings for old patterns
- [ ] Release as minor version (backwards compatible)
- [ ] Gather feedback
- [ ] Plan breaking changes for next major version

## Questions or Issues?

If you encounter any issues during implementation:

1. Check this guide for patterns
2. Look at completed implementations for examples
3. Ensure backwards compatibility is maintained
4. Add tests for all new functionality
5. Document all public APIs with YARD
