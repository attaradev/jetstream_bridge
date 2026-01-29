# Architecture & Topology

This document explains the internal architecture, topology patterns, and message flow of JetStream Bridge.

## Table of Contents

- [Overview](#overview)
- [Core Components](#core-components)
- [Topology Model](#topology-model)
- [Subject Naming & Routing](#subject-naming--routing)
- [Message Flow](#message-flow)
- [Reliability Patterns](#reliability-patterns)
- [Consumer Modes](#consumer-modes)
- [Configuration & Lifecycle](#configuration--lifecycle)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)

---

## Overview

JetStream Bridge provides reliable, production-ready message passing between Ruby/Rails services using NATS JetStream. The architecture is designed around:

1. **Single stream per application pair** - One JetStream stream handles bidirectional communication
2. **Durable consumers** - Each application has a durable consumer (`{app_name}-workers`)
3. **Subject-based routing** - Messages routed via subjects: `{source}.sync.{destination}`
4. **Optional reliability patterns** - Outbox (publisher), Inbox (consumer), and DLQ (both)
5. **Flexible deployment** - Pull or push consumers, with auto or manual provisioning

### Architecture Diagram

```markdown
┌─────────────────┐                    ┌─────────────────┐
│   Application   │                    │   Application   │
│   "api"         │                    │   "worker"      │
├─────────────────┤                    ├─────────────────┤
│                 │                    │                 │
│  Publisher      │                    │  Publisher      │
│  (Optional      │                    │  (Optional      │
│   Outbox)       │                    │   Outbox)       │
│                 │                    │                 │
└────────┬────────┘                    └────────┬────────┘
         │                                      │
         │ Publish to:                          │ Publish to:
         │ api.sync.worker                      │ worker.sync.api
         │                                      │
         └──────────────┐          ┌────────────┘
                        │          │
                        ▼          ▼
                 ┌──────────────────────┐
                 │   NATS JetStream     │
                 │                      │
                 │  Stream: "my-stream" │
                 │  Subjects:           │
                 │   - api.sync.worker  │
                 │   - worker.sync.api  │
                 │   - api.sync.dlq     │
                 │   - worker.sync.dlq  │
                 │                      │
                 │  Consumers:          │
                 │   - api-workers      │
                 │   - worker-workers   │
                 └──────────────────────┘
                        │          │
         ┌──────────────┘          └────────────┐
         │                                      │
         │ Subscribe to:                        │ Subscribe to:
         │ worker.sync.api                      │ api.sync.worker
         │                                      │
┌────────▼────────┐                    ┌────────▼────────┐
│  Consumer       │                    │  Consumer       │
│  (Optional      │                    │  (Optional      │
│   Inbox)        │                    │   Inbox)        │
│                 │                    │                 │
│  DLQ Handler    │                    │  DLQ Handler    │
└─────────────────┘                    └─────────────────┘
```

---

## Core Components

### Connection (`lib/jetstream_bridge/core/connection.rb`)

Thread-safe singleton managing NATS connections:

- Validates NATS URLs and JetStream availability
- Automatic reconnection with configurable retry logic
- Health check API with caching (30s TTL)
- Reconnect handlers for post-fork scenarios (Puma, Sidekiq)
- State management: disconnected → connecting → connected → reconnecting

**Key Methods:**

- `Connection.instance` - Get singleton connection
- `connection.connect!` - Establish NATS connection
- `connection.nats` - Access raw NATS client
- `connection.jetstream` - Access JetStream context
- `connection.healthy?` - Check connection health
- `connection.reconnect!` - Force reconnection

### Publisher (`lib/jetstream_bridge/publisher/publisher.rb`)

Publishes events to JetStream:

- Event envelope construction (event_id, timestamps, schema_version, etc.)
- Resource ID extraction from payload
- Optional outbox pattern for transactional guarantees
- Retry logic with exponential backoff
- Duplicate detection via NATS message ID header

**Usage:**

```ruby
JetstreamBridge.publish(
  resource_type: "user",
  event_type: "user.created",
  payload: { id: 1, email: "user@example.com" }
)
```

**Envelope Structure:**

```json
{
  "event_id": "uuid",
  "event_type": "user.created",
  "resource_type": "user",
  "resource_id": "1",
  "payload": { "id": 1, "email": "user@example.com" },
  "produced_at": "2024-01-01T00:00:00Z",
  "producer": "api",
  "schema_version": "1.0",
  "trace_id": "trace-uuid"
}
```

### Consumer (`lib/jetstream_bridge/consumer/consumer.rb`)

Subscribes to and processes messages:

- Durable consumer creation and subscription binding
- Batch fetching (pull mode) or delivery subject subscription (push mode)
- Message parsing and handler invocation
- Optional inbox pattern for exactly-once processing
- Automatic DLQ routing for unrecoverable errors
- Graceful shutdown with signal handlers

**Usage:**

```ruby
consumer = JetstreamBridge::Consumer.new do |event|
  User.upsert({
    id: event.resource_id,
    email: event.payload["email"]
  })
end

consumer.run! # Blocks and processes messages
```

### Provisioner (`lib/jetstream_bridge/provisioner.rb`)

Creates and updates JetStream streams and consumers:

- Stream creation with work-queue retention
- Subject management and overlap detection
- Consumer creation with delivery policies
- Idempotent operations (safe to re-run)
- Can run at deploy-time with admin credentials or at runtime

**Stream Configuration:**

```ruby
{
  name: "jetstream-bridge-stream",
  retention: :workqueue,
  storage: :file,
  subjects: [
    "api.sync.worker",
    "worker.sync.api",
    "api.sync.dlq",
    "worker.sync.dlq"
  ]
}
```

**Consumer Configuration:**

```ruby
{
  durable_name: "api-workers",
  filter_subject: "worker.sync.api",
  ack_policy: :explicit,
  deliver_policy: :all,
  max_deliver: 5,
  ack_wait: 30_000_000_000, # 30s in nanoseconds
  backoff: [1_000_000_000, 5_000_000_000, ...]
}
```

### Topology (`lib/jetstream_bridge/topology/topology.rb`)

Orchestrates stream and consumer provisioning:

- Overlap guard prevents subject conflicts between streams
- Stream support retries when conflicts occur
- Validates and normalizes subjects
- Coordinates provisioning across components

---

## Topology Model

### Stream Structure

**One stream per application pair** (or shared stream for multiple apps):

```markdown
Stream: "jetstream-bridge-stream"
├── Subjects:
│   ├── api.sync.worker      (api publishes, worker consumes)
│   ├── worker.sync.api      (worker publishes, api consumes)
│   ├── api.sync.dlq         (api's dead letter queue)
│   └── worker.sync.dlq      (worker's dead letter queue)
│
├── Retention: workqueue      (messages deleted after ack)
├── Storage: file             (persistent on disk)
└── Consumers:
    ├── api-workers           (filters: worker.sync.api)
    └── worker-workers        (filters: api.sync.worker)
```

### Subject Pattern

**IMPORTANT:** `app_name` should not include environment identifiers (e.g., use "api" not "api-production"). Consumer names are shared across environments.

#### Source Subject (Publisher)

```ruby
{app_name}.sync.{destination_app}
```

Example: `api.sync.worker`

#### Destination Subject (Consumer)

```ruby
{destination_app}.sync.{app_name}
```

Example: `worker.sync.api` (reverse of source)

#### DLQ Subject

```ruby
{app_name}.sync.dlq
```

Example: `api.sync.dlq`

### Consumer Naming

**Durable consumer name:**

```ruby
{app_name}-workers
```

Example: `api-workers`

**Filter subject:**

```ruby
{destination_app}.sync.{app_name}
```

Example: `worker.sync.api`

---

## Subject Naming & Routing

### Subject Validation

Subjects must:

- Not contain NATS wildcards (`*`, `>`)
- Not contain spaces or control characters
- Not exceed 255 characters
- Use valid characters: alphanumeric, hyphen, underscore, period

### Subject Matching

JetStream Bridge implements NATS wildcard matching:

- `*` - Matches exactly one token (e.g., `api.*.worker` matches `api.sync.worker`)
- `>` - Matches one or more tokens (e.g., `api.>` matches `api.sync.worker`)

### Overlap Detection

The `OverlapGuard` prevents subject conflicts:

```ruby
# Existing stream has: "orders.>"
# New stream wants: "orders.created"
# Result: OVERLAP - "orders.created" would be captured by "orders.>"
```

Overlap detection ensures messages route to exactly one stream.

---

## Message Flow

### Publishing Flow

```markdown
┌──────────────────────────────────────────────────────────────┐
│ 1. Application calls JetstreamBridge.publish(...)           │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Publisher builds envelope                                 │
│    - Generate event_id (UUID)                                │
│    - Extract resource_id from payload                        │
│    - Add timestamps, producer, schema_version                │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. [OPTIONAL] Outbox pattern                                 │
│    - OutboxRepository.record_publish_attempt()               │
│    - State: "publishing"                                     │
│    - Database transaction commits                            │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Publish to NATS JetStream                                 │
│    - Subject: {app_name}.sync.{destination_app}              │
│    - Header: nats-msg-id = event_id (deduplication)          │
│    - Retry with exponential backoff on transient errors      │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. [OPTIONAL] Outbox update                                  │
│    - Success: OutboxRepository.record_publish_success()      │
│    - Failure: OutboxRepository.record_publish_failure()      │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. Return PublishResult                                      │
│    - success: true/false                                     │
│    - event_id: UUID                                          │
│    - duplicate: true/false (if seen before)                  │
└──────────────────────────────────────────────────────────────┘
```

### Consuming Flow

```markdown
┌──────────────────────────────────────────────────────────────┐
│ 1. Application creates Consumer.new { |event| ... }          │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. SubscriptionManager ensures durable consumer              │
│    - Consumer: {app_name}-workers                            │
│    - Filter: {destination_app}.sync.{app_name}               │
│    - Create if not exists (idempotent)                       │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Subscribe to consumer                                     │
│    - Pull mode: $JS.API.CONSUMER.MSG.NEXT.{stream}.{durable}│
│    - Push mode: {delivery_subject}                           │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Consumer.run! starts main loop                            │
│    - Fetch batch of messages                                 │
│    - Process each message sequentially                       │
│    - Idle backoff when no messages (0.05s → 1.0s)            │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. [OPTIONAL] Inbox deduplication check                      │
│    - InboxRepository.find_or_build(event_id)                 │
│    - If already processed → skip and ack                     │
│    - If new → InboxRepository.persist_pre()                  │
│    - State: "processing"                                     │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. MessageProcessor.handle_message()                         │
│    - Parse JSON envelope → Event object                      │
│    - Run middleware chain                                    │
│    - Call user handler block                                 │
│    - Return ActionResult (:ack or :nak)                      │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. Error handling                                            │
│    - Unrecoverable (ArgumentError, TypeError) → DLQ + ack    │
│    - Recoverable (StandardError) → nak with backoff          │
│    - Malformed JSON → DLQ + ack                              │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 8. [OPTIONAL] Inbox update                                   │
│    - Success: InboxRepository.persist_post()                 │
│    - Failure: InboxRepository.persist_failure()              │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ 9. Acknowledge message                                       │
│    - :ack → msg.ack (removes from stream)                    │
│    - :nak → msg.nak(delay: backoff) (requeue for retry)     │
└──────────────────────────────────────────────────────────────┘
```

---

## Reliability Patterns

### Outbox Pattern (Publisher Side)

**Purpose:** Guarantee at-most-once delivery by persisting events to database before publishing.

**Configuration:**

```ruby
config.use_outbox = true
config.outbox_model = 'JetstreamBridge::OutboxEvent'
```

**States:**

- `pending` - Event queued but not yet published
- `publishing` - Currently being published to NATS
- `sent` - Successfully published
- `failed` - Failed after retries
- `exception` - Unexpected error

**Recovery:**

```ruby
# Retry failed events via background job
JetstreamBridge::OutboxEvent.where(status: 'failed').find_each do |event|
  JetstreamBridge.publish(
    event_id: event.event_id,
    resource_type: event.resource_type,
    event_type: event.event_type,
    payload: event.payload
  )
end
```

### Inbox Pattern (Consumer Side)

**Purpose:** Guarantee exactly-once processing by tracking received events in database.

**Configuration:**

```ruby
config.use_inbox = true
config.inbox_model = 'JetstreamBridge::InboxEvent'
```

**States:**

- `received` - Event received but not yet processed
- `processing` - Currently being processed
- `processed` - Successfully processed
- `failed` - Failed processing

**Schema Requirements:**

Generate the inbox events table migration:

```bash
rails generate jetstream_bridge:migration
rails db:migrate
```

**Required Fields:**

| Field | Type | Nullable | Description |
| ----- | ---- | -------- | ----------- |
| `event_id` | string | NO | Unique event identifier for deduplication |
| `event_type` | string | NO | Type of event (e.g., 'created', 'updated') |
| `payload` | text | NO | Full event payload as JSON |
| `status` | string | NO | Processing status (received/processing/processed/failed) |
| `processing_attempts` | integer | NO | Number of processing attempts (default: 0) |
| `created_at` | timestamp | NO | When the record was created |
| `updated_at` | timestamp | NO | When the record was last updated |

**Optional Fields (useful for debugging and querying):**

| Field | Type | Nullable | Description |
| ----- | ---- | -------- | ----------- |
| `resource_type` | string | YES | Type of resource (e.g., 'organization', 'user') |
| `resource_id` | string | YES | ID of the resource being synced |
| `subject` | string | YES | NATS subject the message was received on |
| `headers` | jsonb | YES | NATS message headers |
| `stream` | string | YES | JetStream stream name |
| `stream_seq` | bigint | YES | Stream sequence number (fallback deduplication key) |
| `deliveries` | integer | YES | Number of delivery attempts from NATS |
| `error_message` | text | YES | Error message if processing failed |
| `received_at` | timestamp | YES | When the event was first received |
| `processed_at` | timestamp | YES | When the event was successfully processed |
| `failed_at` | timestamp | YES | When the event failed processing |

**Indexes:**

- `event_id` - Unique index for fast deduplication
- `status` - Index for querying by processing status
- `created_at` - Index for time-based queries
- `(stream, stream_seq)` - Unique composite index for fallback deduplication

**Deduplication:**

- Uses `event_id` for primary deduplication
- Falls back to `stream_seq` if event_id not available
- Database row locking prevents concurrent processing

**Example:**

```ruby
# First delivery
inbox = InboxRepository.find_or_build(event_id: "abc123")
inbox.new_record? # => true
inbox.processed_at # => nil
# Process message...

# Second delivery (redelivery)
inbox = InboxRepository.find_or_build(event_id: "abc123")
inbox.new_record? # => false
inbox.processed_at # => 2024-01-01 00:00:00
# Skip processing, already done
```

**Field Population:**

The InboxRepository automatically extracts and sets fields from the message payload:

```ruby
# Extracted from message body
event_type: msg.body['type'] || msg.body['event_type']
resource_type: msg.body['resource_type']
resource_id: msg.body['resource_id']

# NATS metadata
subject: msg.subject
headers: msg.headers
stream: msg.stream
stream_seq: msg.seq
deliveries: msg.deliveries
```

### Dead Letter Queue (DLQ)

**Purpose:** Route unrecoverable messages to separate subject for manual intervention.

**Configuration:**

```ruby
config.use_dlq = true
```

**Triggered by:**

1. **Malformed JSON** - Cannot parse event envelope
2. **Max deliveries exceeded** - Message failed `config.max_deliver` times
3. **Unrecoverable errors** - ArgumentError, TypeError, NameError

**DLQ Message Headers:**

```json
{
  "x-dead-letter": "true",
  "x-dlq-reason": "max_deliveries_exceeded",
  "x-deliveries": "5",
  "x-dlq-context": {
    "event_id": "abc123",
    "error_class": "StandardError",
    "error_message": "Something went wrong",
    "original_subject": "worker.sync.api",
    "stream_sequence": 42,
    "consumer_sequence": 10,
    "timestamp": "2024-01-01T00:00:00Z"
  }
}
```

**DLQ Subject:**

```ruby
{app_name}.sync.dlq
```

**Monitoring DLQ:**

```bash
# View DLQ messages
nats sub 'api.sync.dlq'

# Check DLQ consumer
nats consumer info jetstream-bridge-stream api-dlq-consumer
```

### Retry Strategy

**Configuration:**

```ruby
config.max_deliver = 5             # Max retry attempts
config.ack_wait = '30s'            # Time before JetStream redelivers
config.backoff = ['1s', '5s', '15s', '30s', '60s']
```

**Backoff Calculation:**

- Base delay: 0.5s (transient errors) or 2.0s (other errors)
- Exponential multiplier: 2^(attempt - 1)
- Min delay: 1 second
- Max delay: 60 seconds

**Example Timeline:**

```shell
Attempt 1 → Fail → NAK with delay 1s
Attempt 2 (1s later) → Fail → NAK with delay 5s
Attempt 3 (5s later) → Fail → NAK with delay 15s
Attempt 4 (15s later) → Fail → NAK with delay 30s
Attempt 5 (30s later) → Fail → NAK with delay 60s
Attempt 6 (60s later) → Fail → DLQ + ACK (max_deliver exceeded)
```

---

## Consumer Modes

### Pull Mode (Default)

**Configuration:**

```ruby
config.consumer_mode = :pull # default
```

**How it works:**

1. Consumer publishes request to `$JS.API.CONSUMER.MSG.NEXT.{stream}.{durable}`
2. JetStream responds with batch of messages (up to `batch_size`)
3. Consumer processes messages and requests next batch

**Advantages:**

- **Backpressure control** - Consumer pulls when ready
- **Restricted permissions** - No JetStream API access needed at runtime
- **Scalability** - Multiple workers pull at their own pace

**Message Fetch:**

```ruby
# Pull request
{
  "batch": 10,
  "max_bytes": 1048576,  # 1MB
  "idle_heartbeat": 5000000000  # 5s
}
```

**Use cases:**

- High-throughput processing
- Variable processing time per message
- Restricted production environments
- Multiple consumer instances

### Push Mode

**Configuration:**

```ruby
config.consumer_mode = :push
config.delivery_subject = 'worker.sync.api.worker' # optional
```

**How it works:**

1. JetStream automatically pushes messages to delivery subject
2. Consumer subscribes to delivery subject
3. Messages arrive as soon as available

**Advantages:**

- **Lower latency** - No request/response roundtrip
- **Simpler model** - Fire-and-forget from JetStream side
- **Good for real-time** - Immediate delivery

**Default Delivery Subject:**

```ruby
{destination_subject}.worker
```

Example: `worker.sync.api.worker`

**Use cases:**

- Low-latency requirements
- Event-driven architectures
- Moderate message volume
- Single consumer instance

### Comparison Table

| Feature | Pull Mode | Push Mode |
|---------|-----------|-----------|
| **Control** | Consumer-driven | Server-driven |
| **Latency** | Slightly higher (request/response) | Lower (immediate push) |
| **Backpressure** | Natural (consumer controls fetch) | Requires management |
| **Permissions** | Works with restricted permissions | Standard permissions |
| **Scalability** | Better for high throughput | Good for moderate load |
| **Complexity** | More API calls | Simpler |
| **Best for** | Batch processing, high volume | Real-time, low volume |

---

## Configuration & Lifecycle

### Configuration Flow

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # Connection
  config.nats_urls = ENV.fetch('NATS_URLS', 'nats://localhost:4222')
  config.stream_name = 'jetstream-bridge-stream'

  # Application identity (no environment suffix!)
  config.app_name = 'api'
  config.destination_app = 'worker'

  # Reliability
  config.use_outbox = true
  config.use_inbox = true
  config.use_dlq = true

  # Consumer tuning
  config.max_deliver = 5
  config.ack_wait = '30s'
  config.backoff = %w[1s 5s 15s 30s 60s]

  # Consumer mode
  config.consumer_mode = :pull # or :push

  # Provisioning
  config.auto_provision = true # false for restricted environments

  # Connection management
  config.connect_retry_attempts = 3
  config.connect_retry_delay = 2
  config.lazy_connect = false
end
```

### Startup Lifecycle

**Automatic (Rails):**

```ruby
# Railtie automatically calls after initialization:
JetstreamBridge.startup!
```

**Manual:**

```ruby
# Non-Rails or custom boot
JetstreamBridge.startup!
```

**Lazy Connect:**

```ruby
config.lazy_connect = true
# OR
ENV['JETSTREAM_BRIDGE_DISABLE_AUTOSTART'] = '1'

# Connection happens on first publish/subscribe
```

**Startup Steps:**

1. Validate configuration
2. Connect to NATS
3. Verify JetStream availability
4. Ensure stream topology (if `auto_provision=true`)
5. Cache connection for reuse

### Provisioning Modes

#### Auto Provisioning (Default)

**Configuration:**

```ruby
config.auto_provision = true
```

**Behavior:**

- Creates streams and consumers at runtime
- Requires JetStream API permissions
- Idempotent (safe to re-run)

#### Manual Provisioning

**Configuration:**

```ruby
config.auto_provision = false
```

**Provisioning at deploy time:**

```bash
# Using rake task with admin credentials
NATS_URLS=nats://admin:pass@host:4222 \
bundle exec rake jetstream_bridge:provision
```

**Benefits:**

- Runtime credentials don't need admin permissions
- Separate provisioning from application lifecycle
- Better security posture

See [RESTRICTED_PERMISSIONS.md](RESTRICTED_PERMISSIONS.md) for details.

### Reconnection Handling

**Automatic reconnection:**

```ruby
# NATS client auto-reconnects on network failures
# JetstreamBridge preserves JetStream context
```

**Manual reconnection:**

```ruby
# After forking (Puma, Sidekiq)
JetstreamBridge.reconnect!

# Example: Puma config
on_worker_boot do
  JetstreamBridge.reconnect!
end
```

---

## Error Handling

### Error Categories

#### Unrecoverable Errors

**Types:**

- `ArgumentError` - Invalid arguments
- `TypeError` - Type mismatch
- `NameError` - Undefined constant/method

**Handling:**

1. Log error with full context
2. Publish to DLQ with `x-dlq-reason: unrecoverable_error`
3. ACK message (remove from stream)

#### Recoverable Errors

**Types:**

- `StandardError` (default)
- Transient failures (network, timeouts)
- Retryable business logic errors

**Handling:**

1. Log error with delivery count
2. NAK message with backoff delay
3. JetStream redelivers after delay
4. After `max_deliver` attempts → DLQ

#### Malformed Messages

**Types:**

- JSON parse errors
- Invalid envelope structure

**Handling:**

1. Log raw message data
2. Publish to DLQ with `x-dlq-reason: malformed_json`
3. ACK message (remove from stream)

### Error Context

**Logged Information:**

```ruby
{
  error_class: "StandardError",
  error_message: "Database connection lost",
  event_id: "abc123",
  resource_type: "user",
  event_type: "user.created",
  delivery_count: 3,
  stream_sequence: 42,
  consumer_sequence: 10,
  subject: "worker.sync.api",
  backtrace: [...]
}
```

### Custom Error Handling

**Middleware approach:**

```ruby
class CustomErrorHandler
  def call(event, next_middleware)
    next_middleware.call(event)
  rescue CustomRetryableError => e
    # Return ActionResult with custom delay
    JetstreamBridge::Consumer::ActionResult.new(:nak, delay: 10)
  rescue CustomPermanentError => e
    # Log and move to DLQ
    logger.error("Permanent error: #{e.message}")
    publish_to_custom_dlq(event, e)
    JetstreamBridge::Consumer::ActionResult.new(:ack)
  end
end

consumer.use(CustomErrorHandler.new)
```

---

## Thread Safety

### Connection Singleton

**Thread-safe initialization:**

```ruby
@@connection_lock = Mutex.new

def self.instance
  return @@connection if @@connection

  @@connection_lock.synchronize do
    @@connection ||= new
  end

  @@connection
end
```

**Health check cache:**

```ruby
# Thread-safe cache updates
@health_cache_lock.synchronize do
  @health_cache = { data: health_data, cached_at: Time.now }
end
```

### Consumer Processing

**Single-threaded by design:**

- Fetch batch → Process sequentially → Fetch next batch
- No concurrent message processing within one consumer instance
- Multiple consumer instances for parallelism

**Inbox Row Locking:**

```ruby
# Prevents concurrent processing of same event_id
InboxEvent.lock.find_or_create_by!(event_id: event.event_id) do |inbox|
  inbox.status = 'processing'
end
```

### Publisher

**Thread-safe publishing:**

- No global state mutation
- Independent envelope generation per call
- Outbox uses AR transactions for atomicity

**Concurrent publishing:**

```ruby
# Safe to call from multiple threads
threads = 10.times.map do |i|
  Thread.new do
    JetstreamBridge.publish(
      resource_type: 'user',
      event_type: 'user.created',
      payload: { id: i }
    )
  end
end

threads.each(&:join)
```

### Best Practices

1. **One consumer per process** - Avoid multiple consumer loops in one process
2. **Fork safety** - Call `JetstreamBridge.reconnect!` after forking
3. **Database connections** - ActiveRecord handles connection pooling
4. **Signal handling** - Consumer handles INT/TERM for graceful shutdown

---

## Performance Considerations

### Batch Size

**Pull mode:**

```ruby
consumer = JetstreamBridge::Consumer.new(batch_size: 10) do |event|
  # Process event
end
```

**Trade-offs:**

- **Small batch (1-5):** Lower latency, more API calls
- **Medium batch (10-50):** Balanced latency and throughput
- **Large batch (50+):** Higher throughput, risk of processing timeouts

### Idle Backoff

**Exponential backoff when no messages:**

```markdown
0.05s → 0.1s → 0.2s → 0.4s → 0.8s → 1.0s (max)
```

**Benefit:** Reduces CPU and network usage during idle periods

### Connection Pooling

**Single connection per process:**

- NATS client maintains connection pool internally
- JetStream context cached for reuse
- No need for application-level pooling

### Memory Management

**Long-running consumers:**

- Periodic health checks every 10 minutes
- Memory monitoring can be added via middleware
- Graceful shutdown prevents memory leaks

---

## Observability

### Health Checks

```ruby
health = JetstreamBridge.health_check(skip_cache: false)

{
  healthy: true,
  connection: {
    status: "connected",
    servers: ["nats://localhost:4222"],
    connected_at: "2024-01-01T00:00:00Z"
  },
  jetstream: {
    streams: 1,
    consumers: 2,
    memory_bytes: 104857600,
    storage_bytes: 1073741824
  },
  config: {
    stream_name: "jetstream-bridge-stream",
    app_name: "api",
    destination_app: "worker",
    use_outbox: true,
    use_inbox: true,
    use_dlq: true
  },
  performance: {
    message_processing_time_ms: 45.2,
    last_health_check_ms: 12.5
  }
}
```

### Logging

**Structured logging:**

```ruby
# Publisher
INFO  [JetstreamBridge::Publisher] Published api.sync.worker event_id=abc123
DEBUG [JetstreamBridge::Publisher] Envelope: {...}

# Consumer
INFO  [JetstreamBridge::Consumer] Processing message event_id=abc123
WARN  [JetstreamBridge::Consumer] Retry 3/5 for event_id=abc123
ERROR [JetstreamBridge::Consumer] Unrecoverable error: ArgumentError
```

### Metrics Points

**Consider tracking:**

- Message publish rate and latency
- Message processing rate and latency
- Error rates by type
- DLQ message count
- Inbox/outbox table sizes
- Consumer lag (JetStream consumer info)

**Example with middleware:**

```ruby
class MetricsMiddleware
  def call(event, next_middleware)
    start = Time.now
    result = next_middleware.call(event)
    duration = Time.now - start

    StatsD.increment('jetstream.messages.processed')
    StatsD.histogram('jetstream.processing_time', duration)

    result
  rescue => e
    StatsD.increment('jetstream.messages.failed', tags: ["error:#{e.class}"])
    raise
  end
end
```

---

## Best Practices

1. **App name without environment** - Use "api" not "api-production" for consumer name consistency
2. **Idempotent handlers** - Design handlers to be safely retried
3. **Enable outbox in production** - Prevents message loss on crashes
4. **Enable inbox for critical flows** - Guarantees exactly-once processing
5. **Monitor DLQ** - Set up alerts for messages in dead letter queue
6. **Provision separately** - Use manual provisioning in locked-down environments
7. **Health check endpoint** - Expose `JetstreamBridge.health_check` for monitoring
8. **Graceful shutdown** - Consumer handles signals automatically
9. **Test with Mock NATS** - Fast, no-infra testing (see [TESTING.md](TESTING.md))
10. **Tune batch size** - Balance latency vs throughput for your workload

---

## Next Steps

- [Getting Started Guide](GETTING_STARTED.md) - Basic setup and usage
- [Production Guide](PRODUCTION.md) - Production deployment patterns
- [Restricted Permissions](RESTRICTED_PERMISSIONS.md) - Manual provisioning and security
- [Testing Guide](TESTING.md) - Testing with Mock NATS
