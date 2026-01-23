# Working with Restricted NATS Permissions

This guide explains how to use JetStream Bridge when your NATS user lacks JetStream API permissions (`$JS.API.*` subjects).

## Problem

When the NATS user has restricted permissions and cannot access JetStream API subjects, you'll see errors like:

```markdown
ERROR -- : [JetstreamBridge::ConnectionManager] NATS error: 'Permissions Violation for Publish to "$JS.API.CONSUMER.INFO.{stream}.{consumer}"'
NATS::IO::Timeout: nats: timeout
```

This happens because:

1. JetStream Bridge tries to verify consumer configuration using `$JS.API.CONSUMER.INFO.*`
2. The NATS user doesn't have permission to publish to these API subjects
3. The connection is terminated, causing timeout errors

## Solution Overview

When you cannot modify NATS server permissions, you need to:

0. **Turn off runtime provisioning** so the app never calls `$JS.API.*`:
   - Set `config.auto_provision = false`
   - Provision stream + consumer once with admin credentials (CLI below or `bundle exec rake jetstream_bridge:provision`)
1. **Pre-create the consumer** using a privileged NATS account
2. **Ensure the consumer configuration matches** what your app expects

> Tip: When `auto_provision=false`, the app still connects/publishes/consumes but skips JetStream management APIs (account_info, stream_info, consumer_info). Health checks will report basic connectivity only.

---

## Runtime requirements (least privilege)

- Config: `config.auto_provision = false`, `config.stream_name` set explicitly.
- Topology: stream + durable consumer must be pre-provisioned (via `bundle exec rake jetstream_bridge:provision` or NATS CLI).
- NATS permissions for runtime creds:
  - publish allow: `">"` (or narrowed to your business subjects) and `$JS.API.CONSUMER.MSG.NEXT.{stream_name}.{app_name}-workers`
  - subscribe allow: `">"` (or narrowed) and `_INBOX.>` (responses for pull consumers)
- Health check will only report connectivity (stream info skipped).

### Topology required

- Stream: `config.stream_name` (retention: workqueue, storage: file).
- Subjects:
  - Publish: `{app_name}.sync.{destination_app}`
  - Consume: `{destination_app}.sync.{app_name}`
  - DLQ (if enabled): `{app_name}.sync.dlq`
- Durable consumer: `{app_name}-workers` filtering on `{destination_app}.sync.{app_name}`.

---

## Option A: Provision with the built-in task (creates stream + consumer)

Run this from CI/deploy with admin NATS credentials:

```bash
# Uses your configured stream/app/destination to create the stream + durable consumer
NATS_URLS="nats://admin:pass@10.199.12.34:4222" \
bundle exec rake jetstream_bridge:provision
```

This is the easiest way to keep `auto_provision=false` in runtime while still reusing the bridge’s topology logic (subjects, DLQ, overlap guard).

## Option B: Pre-create the Consumer using NATS CLI

### Install NATS CLI

```bash
# Download from https://github.com/nats-io/natscli/releases
curl -sf https://binaries.nats.dev/nats-io/natscli/nats@latest | sh

# Or using Homebrew (macOS)
brew install nats-io/nats-tools/nats
```

### Create the Consumer

You need to create a durable pull consumer with the exact configuration your app expects.

**Required values from your JetStream Bridge config:**

- **Stream name**: `JETSTREAM_STREAM_NAME` (e.g., `jetstream-bridge-stream`)
- **Consumer name**: `{app_name}-workers` (e.g., `pwas-workers`)
- **Filter subject**: `{app_name}.sync.{destination_app}` (e.g., `pwas-workers.sync.heavyworth`)

**Create consumer command:**

```bash
# Connect using a privileged NATS account
nats context save admin \
  --server=nats://admin-user:admin-pass@10.199.12.34:4222 \
  --description="Admin account for consumer creation"

# Select the context
nats context select admin

# Create the consumer
nats consumer add production-jetstream-bridge-stream production-pwas-workers \
  --filter "production.pwas-workers.sync.heavyworth" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --replay instant \
  --max-pending 25000
```

**With backoff (recommended for production):**

```bash
nats consumer add production-jetstream-bridge-stream production-pwas-workers \
  --filter "production.pwas-workers.sync.heavyworth" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000
```

### Verify Consumer Creation

```bash
nats consumer info production-jetstream-bridge-stream production-pwas-workers
```

Expected output:

```bash
Information for Consumer production-jetstream-bridge-stream > production-pwas-workers

Configuration:

        Durable Name: production-pwas-workers
      Filter Subject: production.pwas-workers.sync.heavyworth
          Ack Policy: explicit
            Ack Wait: 30s
       Replay Policy: instant
  Maximum Deliveries: 5
             Backoff: [1s 5s 15s 30s 60s]

State:

  Last Delivered Message: Consumer sequence: 0 Stream sequence: 0
    Acknowledgment Floor: Consumer sequence: 0 Stream sequence: 0
        Pending Messages: 0
    Redelivered Messages: 0
```

---

## Step 2: Configure JetStream Bridge

Configure JetStream Bridge to avoid JetStream management APIs at runtime (pre-provisioning handles them instead):

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls = ENV.fetch("NATS_URLS")
  config.stream_name = "jetstream-bridge-stream"
  config.app_name = "pwas-workers"
  config.destination_app = "heavyworth"
  config.auto_provision = false

  config.use_outbox = true
  config.use_inbox = true
  config.use_dlq = true

  # These settings MUST match the pre-created consumer
  config.max_deliver = 5
  config.ack_wait = "30s"
  config.backoff = %w[1s 5s 15s 30s 60s]
end
```

**Critical:** The `max_deliver`, `ack_wait`, and `backoff` values in your config **must exactly match** the pre-created consumer configuration. If they don't match, messages may be redelivered incorrectly.

---

## Step 3: Deploy and Verify

### Deploy the Updated Gem

If you're working on the jetstream_bridge gem itself:

```bash
# Build the gem
gem build jetstream_bridge.gemspec

# Install locally for testing
gem install ./jetstream_bridge-4.5.0.gem

# Or update in your application's Gemfile.lock
bundle update jetstream_bridge
```

If this is a local modification, you can point your Gemfile to the local path:

```ruby
# Gemfile (temporary for testing)
gem 'jetstream_bridge', path: '/path/to/local/jetstream_bridge'
```

### Restart the Service

```bash
sudo systemctl restart pwas_production_sync
```

### Monitor the Logs

```bash
sudo journalctl -u pwas_production_sync -f
```

**Expected success output:**

```bash
INFO -- : [JetstreamBridge::ConnectionManager] Connected to NATS (1 server): nats://pwas:***@10.199.12.34:4222
INFO -- : [DataSync] Consumer starting (durable=production-pwas-workers, batch=25, dest="heavyworth")
INFO -- : [DataSync] run! started successfully
```

Health checks will report connectivity only when `auto_provision=false` (stream info is skipped to avoid `$JS.API.STREAM.INFO`).

**If you still see errors:**

1. **Timeout during subscribe** - The pre-created consumer name/filter might not match. Verify:

   ```bash
   nats consumer ls production-jetstream-bridge-stream
   ```

2. **Permission violations on fetch** - The NATS user also needs permission to fetch messages. Minimum required:

   ```conf
   subscribe: {
     allow: ["production.>", "_INBOX.>"]
   }
   ```

## Maintenance

### Updating Consumer Configuration

If you need to change consumer settings (e.g., increase `max_deliver`):

1. **Stop your application** to prevent message processing

   ```bash
   sudo systemctl stop pwas_production_sync
   ```

2. **Delete the old consumer** (using privileged account)

   ```bash
   nats consumer rm production-jetstream-bridge-stream production-pwas-workers -f
   ```

3. **Create the new consumer** with updated settings

   ```bash
   nats consumer add production-jetstream-bridge-stream production-pwas-workers \
     --filter "production.pwas-workers.sync.heavyworth" \
     --ack explicit \
     --pull \
     --deliver all \
     --max-deliver 10 \
     --ack-wait 60s \
     --backoff 2s,10s,30s,60s,120s \
     --replay instant \
     --max-pending 25000
   ```

4. **Update your application config** to match

   ```ruby
   config.max_deliver = 10
   config.ack_wait = "60s"
   config.backoff = %w[2s 10s 30s 60s 120s]
   ```

5. **Restart your application**

   ```bash
   sudo systemctl start pwas_production_sync
   ```

### Monitoring

Add monitoring to detect configuration drift:

```ruby
# Check consumer exists and is healthy
health = JetstreamBridge.health_check
unless health[:healthy]
  alert("JetStream consumer unhealthy: #{health}")
end
```

---

## Troubleshooting

### Consumer doesn't receive messages

**Check stream has messages:**

```bash
nats stream info production-jetstream-bridge-stream
```

**Verify filter subject matches your topology:**

```bash
# App publishes to:   {app_name}.sync.{destination_app}
# Consumer filters on: {destination_app}.sync.{app_name}
```

### Service keeps restarting

Check if the issue is:

1. **Consumer doesn't exist** - Pre-create it with NATS CLI
2. **Filter subject mismatch** - Verify with `nats consumer info`
3. **Permissions still insufficient** - User needs subscribe permissions on the filtered subject
4. **Wrong stream name** - Ensure stream name matches your configured `config.stream_name`

---

## Security Considerations

1. **Consumer pre-creation requires privileged access** - Keep admin credentials secure
2. **Configuration drift risk** - If app config doesn't match consumer config, message delivery may fail silently
3. **No automatic recovery** - If consumer is deleted, it won't be recreated automatically
4. **Consider automation** - Use infrastructure-as-code (Terraform, Ansible) to manage consumer creation

---

## Example: Production Setup for pwas-api

Based on your logs, here's the exact setup:

```bash
# 1. Pre-create the consumer (as admin)
nats consumer add pwas-heavyworth-sync production-pwas-workers \
  --filter "production.pwas-workers.sync.heavyworth" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant
```

```ruby
# 2. Update config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls = "nats://pwas:***@10.199.12.34:4222"
  config.stream_name = "jetstream-bridge-stream"
  config.app_name = "pwas-workers"
  config.destination_app = "heavyworth"
  config.max_deliver = 5
  config.ack_wait = "30s"
  config.backoff = %w[1s 5s 15s 30s 60s]
end
```

**Note:** Verify your exact stream name and consumer durable (`app_name-workers`) match what was provisioned.

---

## Alternative: Request Minimal Permissions

If you have any influence over NATS permissions, request only these minimal subjects:

```conf
# Minimal permissions needed for JetStream Bridge consumer
publish: {
  allow: [
    ">",                                   # Your app subjects (narrow if desired)
    "$JS.API.CONSUMER.MSG.NEXT.{stream_name}.{app_name}-workers",  # Fetch messages (required)
  ]
}
subscribe: {
  allow: [
    ">",                                   # Your app subjects (narrow if desired)
    "_INBOX.>",                            # Request-reply responses (required)
  ]
}
```

These are read-only operations and don't allow creating/modifying streams or consumers.
