# Non-Restrictive Environment Example

This example demonstrates syncing between two Rails 7 systems using JetStream Bridge in a **non-restrictive environment** where applications have full permissions to create streams and consumers automatically.

## Architecture Overview

```markdown
         ┌─────────────────────────┐
         │  NATS JetStream         │
         │  Stream: sync-stream    │
         │  Auto-provisioned by    │
         │  applications           │
         │                         │
         │  Subjects:              │
         │  - system_a.sync.system_b (A→B)
         │  - system_b.sync.system_a (B→A)
         └──┬──────────────────▲───┘
            │                  │
            │ ┌────────────────┘
            │ │  Bidirectional Sync (A ↔ B)
            ▼ │                │ ▲
┌─────────────┴──┐      ┌──────┴─▲─────────┐
│  System A      │      │  System B        │
│  Pub + Consumer│      │  Pub + Consumer  │
│                │      │                  │
│ - Creates      │      │ - Creates        │
│ - Updates      │      │ - Updates        │
│ - Syncs from B │      │ - Syncs from A   │
│   Orgs/Users   │      │   Orgs/Users     │
└────────────────┘      └──────────────────┘
    PostgreSQL              PostgreSQL
   (system_a_db)           (system_b_db)
```

## Key Features

- **Bidirectional Sync**: Both systems can create/update data that syncs to the other
- **Auto-Provisioning**: Applications automatically create streams and consumers
- **Transactional Outbox**: Both systems use outbox pattern for reliable publishing
- **Idempotent Inbox**: Both systems use inbox pattern for exactly-once processing
- **Cyclic Sync Prevention**: `skip_publish` flag prevents infinite sync loops
- **At-Most-Once Delivery**: With idempotency guarantees
- **Dead Letter Queue**: Failed messages routed to DLQ after max retries

## Domain Model

Both systems sync the following entities:

- **Organization**: Company/tenant entity (name, domain, active)
- **User**: User entity (name, email, role, active, organization_id)

## Prerequisites

- Docker and Docker Compose
- curl (for testing)

## Quick Start

### 1. Start All Services

```bash
cd examples/non_restrictive
docker-compose up -d
```

This starts:

- NATS JetStream (port 4222, monitoring on 8222)
- PostgreSQL for System A (host port 55432 → container 5432)
- PostgreSQL for System B (host port 55433 → container 5432)
- System A Rails API (port 3000)
- System A Consumer (background process)
- System B Rails API (port 3001)
- System B Consumer (background process)

### 2. Wait for Services to Be Ready

```bash
# Check service health
docker-compose ps

# Watch logs
docker-compose logs -f system_a system_b_consumer
```

### 3. Test Sync A → B: Create an Organization in System A

```bash
curl -X POST http://localhost:3000/organizations \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Acme Corp",
      "domain": "acme.com",
      "active": true
    }
  }'
```

Expected response:

```json
{
  "id": 1,
  "name": "Acme Corp",
  "domain": "acme.com",
  "active": true,
  "created_at": "2026-01-29T...",
  "updated_at": "2026-01-29T..."
}
```

### 4. Verify It Synced to System B

```bash
# Check if organization synced to System B
curl http://localhost:3001/organizations

# Check sync status
curl http://localhost:3001/sync_status
```

Expected sync_status response:

```json
{
  "organizations_count": 1,
  "users_count": 0,
  "last_organization_sync": "2026-01-29T...",
  "last_user_sync": null,
  "jetstream_connected": true,
  "inbox_events_count": 1,
  "processed_events_count": 1,
  "failed_events_count": 0
}
```

### 5. Create a User in System A

```bash
curl -X POST http://localhost:3000/users \
  -H "Content-Type: application/json" \
  -d '{
    "user": {
      "organization_id": 1,
      "name": "Alice Smith",
      "email": "alice@acme.com",
      "role": "admin",
      "active": true
    }
  }'
```

### 6. Verify User Synced to System B

```bash
curl http://localhost:3001/users
```

### 7. Update an Organization

```bash
curl -X PATCH http://localhost:3000/organizations/1 \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Acme Corporation"
    }
  }'
```

### 8. Verify Update Synced

```bash
curl http://localhost:3001/organizations/1
```

### 9. Test Sync B → A: Create Data in System B

```bash
# Create organization in System B
curl -X POST http://localhost:3001/organizations \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Beta Inc",
      "domain": "beta.com",
      "active": true
    }
  }'
```

### 10. Verify It Synced Back to System A

```bash
# Wait a few seconds, then check System A
curl http://localhost:3000/organizations

# Should see both Acme Corp and Beta Inc
```

## Complete Test Script

Run the included test script to verify end-to-end sync:

```bash
./test_sync.sh
```

## Monitoring

### View Consumer Logs

```bash
# System A consumer (processes events from B)
docker-compose logs -f system_a_consumer

# System B consumer (processes events from A)
docker-compose logs -f system_b_consumer
```

### Check NATS JetStream Status

```bash
# Access NATS container
docker-compose exec nats sh

# List streams
nats stream list

# Show stream info
nats stream info sync-stream

# List consumers
nats consumer list sync-stream

# Show consumer info
nats consumer info sync-stream system_b-workers
```

### Check Outbox Events (System A)

```bash
docker-compose exec system_a bundle exec rails console

# In Rails console:
JetstreamBridge::OutboxEvent.all
JetstreamBridge::OutboxEvent.where(status: 'sent').count
JetstreamBridge::OutboxEvent.where(status: 'failed').count
```

### Check Inbox Events (System B)

```bash
docker-compose exec system_b_web bundle exec rails console

# In Rails console:
JetstreamBridge::InboxEvent.all
JetstreamBridge::InboxEvent.where(status: 'processed').count
JetstreamBridge::InboxEvent.where(status: 'failed').count
```

## Configuration Details

### System A Configuration

See [system_a/config/initializers/jetstream_bridge.rb](system_a/config/initializers/jetstream_bridge.rb)

Key settings:

- `auto_provision: true` - Automatically creates streams/consumers
- `use_outbox: true` - Transactional outbox for reliable publishing
- `use_inbox: true` - Idempotent inbox for exactly-once processing
- `app_name: "system_a"`
- `destination_app: "system_b"` - Publishes to B, receives from B

### System B Configuration

See [system_b/config/initializers/jetstream_bridge.rb](system_b/config/initializers/jetstream_bridge.rb)

Key settings:

- `auto_provision: true` - Automatically creates streams/consumers
- `use_outbox: true` - Transactional outbox for reliable publishing
- `use_inbox: true` - Idempotent inbox for exactly-once processing
- `app_name: "system_b"`
- `destination_app: "system_a"` - Publishes to A, receives from A

## Event Flow

### System A → System B

1. **Create/Update in System A**:
   - User creates/updates Organization or User via API
   - ActiveRecord `after_commit` callback triggers
   - Event stored in `outbox_events` table
   - JetStream Bridge publishes to NATS subject `system_a.sync.system_b`
   - Message delivered to stream `sync-stream`

2. **Consume in System B**:
   - Consumer polls NATS JetStream
   - Fetches batch of messages from `system_a.sync.system_b`
   - Stores event in `inbox_events` table (deduplication)
   - Calls `EventConsumer.process_event(event)`
   - Updates Organization/User via `sync_from_event(event, skip_publish: true)` (prevents cycle)
   - Acknowledges message to NATS

### System B → System A

1. **Create/Update in System B**:
   - User creates/updates Organization or User via API
   - ActiveRecord `after_commit` callback triggers
   - Event stored in `outbox_events` table
   - JetStream Bridge publishes to NATS subject `system_b.sync.system_a`
   - Message delivered to stream `sync-stream`

2. **Consume in System A**:
   - Consumer polls NATS JetStream
   - Fetches batch of messages from `system_b.sync.system_a`
   - Stores event in `inbox_events` table (deduplication)
   - Calls `EventConsumer.process_event(event)`
   - Updates Organization/User via `sync_from_event(event, skip_publish: true)` (prevents cycle)
   - Acknowledges message to NATS

## Idempotency and Cyclic Prevention

Both systems implement idempotency and cyclic sync prevention:

- **Outbox (Both Systems)**: Tracks published events, prevents duplicates via NATS message ID
- **Inbox (Both Systems)**: Tracks received events, skips duplicates via event_id unique constraint
- **Timestamp Checking**: Ignores older events if newer data already exists
- **Cyclic Prevention**: `skip_publish: true` parameter prevents models from republishing received events, avoiding infinite sync loops between systems

## Error Handling

- **Transient Errors**: Automatic retry with exponential backoff (1s, 5s, 15s, 30s, 60s)
- **Max Retries**: After 5 attempts, message routed to Dead Letter Queue
- **Poison Messages**: DLQ prevents blocking of message stream
- **Logging**: All errors logged with stack traces

## Cleanup

```bash
# Stop services
docker-compose down

# Remove volumes (deletes all data)
docker-compose down -v
```

## API Endpoints

### System A (Publisher + Consumer)

- `POST /organizations` - Create organization (triggers sync to B)
- `PATCH /organizations/:id` - Update organization (triggers sync to B)
- `GET /organizations` - List organizations (local + synced from B)
- `GET /organizations/:id` - Get organization
- `POST /users` - Create user (triggers sync to B)
- `PATCH /users/:id` - Update user (triggers sync to B)
- `GET /users` - List users (local + synced from B)
- `GET /users/:id` - Get user
- `GET /health` - Health check

### System B (Publisher + Consumer)

- `POST /organizations` - Create organization (triggers sync to A)
- `PATCH /organizations/:id` - Update organization (triggers sync to A)
- `GET /organizations` - List organizations (local + synced from A)
- `GET /organizations/:id` - Get organization
- `POST /users` - Create user (triggers sync to A)
- `PATCH /users/:id` - Update user (triggers sync to A)
- `GET /users` - List users (local + synced from A)
- `GET /users/:id` - Get user
- `GET /sync_status` - Check sync status and metrics
- `GET /health` - Health check

## Troubleshooting

### Consumer not receiving events

```bash
# Check consumer logs
docker-compose logs system_b_consumer

# Verify NATS connection
docker-compose exec system_b_consumer bundle exec rake jetstream_bridge:health

# Check stream exists
docker-compose exec nats nats stream info sync-stream
```

### Events stuck in outbox

```bash
# Check outbox events
docker-compose exec system_a bundle exec rails console
JetstreamBridge::OutboxEvent.where(status: 'pending')

# Manually trigger outbox processor (if needed)
# The library auto-processes on publish, but you can manually trigger:
JetstreamBridge::OutboxRepository.new.process_pending!
```

### Database connection issues

```bash
# Check postgres health
docker-compose ps postgres_a postgres_b

# Restart services
docker-compose restart system_a system_b_web system_b_consumer
```

## What Makes This "Non-Restrictive"?

This example demonstrates the **simplest deployment model** for bidirectional sync:

- ✅ Applications have full NATS permissions
- ✅ Both systems automatically create streams and consumers on startup
- ✅ Bidirectional subjects auto-provisioned (A→B and B→A)
- ✅ No manual provisioning required
- ✅ Configuration via environment variables only
- ✅ Both systems run publisher and consumer roles
- ✅ Ideal for development and environments where apps have admin access

For production environments with strict permissions, see the [**restrictive example**](../restrictive/README.md).
