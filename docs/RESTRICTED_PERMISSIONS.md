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

When you cannot modify NATS server permissions, you have **two options**:

### Option 1: Pull Consumers (Default)

- **Requires** permission to publish to `$JS.API.CONSUMER.MSG.NEXT.*`
- Provides backpressure control and batch fetching
- Best for high-throughput scenarios

### Option 2: Push Consumers (New)

- **No JetStream API permissions required** at runtime
- Messages delivered automatically to a subscription subject
- Simpler permission model: only needs subscribe on delivery subject + publish on `$JS.ACK` for acks
- Best for restricted permission environments

For both options, you need to:

0. **Turn off runtime provisioning** so the app never calls `$JS.API.*` for stream creation:
   - Set `config.auto_provision = false`
   - Provision the **stream** once with admin credentials (CLI below or `bundle exec rake jetstream_bridge:provision`)
1. **Ensure the stream exists** - consumers are auto-created when subscribing, but the stream must be provisioned separately
2. **Optionally pre-create the consumer** using a privileged NATS account (consumers are auto-created if missing)

> **Note (v7.1.0+):** Consumers are now auto-created on subscription regardless of the `auto_provision` setting. The `auto_provision` setting only controls stream topology creation. If the stream doesn't exist, subscription will fail with `StreamNotFoundError`.

> Tip: When `auto_provision=false`, the app still connects/publishes/consumes but skips JetStream management APIs (account_info, stream_info) for stream creation. Health checks will report basic connectivity only.

---

## Using Push Consumers (Recommended for Restricted Permissions)

If your NATS user can only publish to specific subjects (e.g., `pwas.*`) and subscribe to specific subjects (e.g., `heavyworth.*`), use **push consumer mode**:

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  config.nats_urls = ENV.fetch("NATS_URLS")
  config.stream_name = "pwas-heavyworth-sync"
  config.app_name = "pwas"
  config.destination_app = "heavyworth"
  config.auto_provision = false

  # Enable push consumer mode
  config.consumer_mode = :push
  # Optional: customize delivery subject (defaults to {destination_subject}.worker)
  # config.delivery_subject = "heavyworth.sync.pwas.worker"

  config.use_outbox = true
  config.use_inbox = true
  config.use_dlq = true

  config.max_deliver = 5
  config.ack_wait = "30s"
  config.backoff = %w[1s 5s 15s 30s 60s]
end
```

### Required Permissions for Push Consumers

```conf
# NATS user permissions (e.g., pwas user)
publish: {
  allow: [
    "pwas.>",                                                    # Your business subjects
    "$JS.ACK.pwas-heavyworth-sync.pwas-workers.>",              # Ack/nak messages (required)
  ]
}
subscribe: {
  allow: [
    "heavyworth.>",  # Your business subjects (includes delivery subject)
  ]
}
```

**No `$JS.API.*` or `_INBOX.>` permissions needed!** However, `$JS.ACK` publish permission is required for the consumer to acknowledge messages. Without it, messages will be redelivered until `max_deliver` is exhausted.

### Provisioning Push Consumers

When creating the consumer, add `--deliver` to specify the delivery subject:

```bash
# For pwas app (receives heavyworth -> pwas)
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
  --deliver "heavyworth.sync.pwas.worker" \
  --ack explicit \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000
```

**Important:** The delivery subject must match what the app can subscribe to based on its permissions.

---

## Runtime requirements (least privilege)

- Config: `config.auto_provision = false`, `config.stream_name` set explicitly.
- Topology: **one shared stream per app pair**, with one durable consumer per app (each filters the opposite direction). Pre-provision via `bundle exec rake jetstream_bridge:provision` or NATS CLI.
- NATS permissions for runtime creds:
  - **Pull consumers** (default):
    - publish allow: `{app_name}.>`, `$JS.API.CONSUMER.MSG.NEXT.{stream_name}.{app_name}-workers`, and `$JS.ACK.{stream_name}.{app_name}-workers.>`
    - subscribe allow: `{destination_app}.>` and `_INBOX.>` (responses for pull consumers)
  - **Push consumers** (recommended for restricted environments):
    - publish allow: `{app_name}.>` and `$JS.ACK.{stream_name}.{app_name}-workers.>` (ack/nak)
    - subscribe allow: `{destination_app}.>` (includes delivery subject)
    - No `$JS.API.*` or `_INBOX.>` permissions needed
- Health check will only report connectivity (stream info skipped).

### Topology required

- Stream: `config.stream_name` (retention: workqueue, storage: file).
- Subjects:
  - Publish: `{app_name}.sync.{destination_app}`
  - Consume: `{destination_app}.sync.{app_name}`
  - DLQ (if enabled): `{app_name}.sync.dlq`
- Durable consumer: `{app_name}-workers` filtering on `{destination_app}.sync.{app_name}`.

---

### Connectivity check with restricted creds

After setting `config.auto_provision = false`, you can still confirm basic connectivity without touching `$JS.API.*` by running:

```bash
bundle exec rake jetstream_bridge:test_connection
```

In this mode the task performs a NATS ping and JetStream client setup only; it assumes the stream + consumer are already provisioned with admin credentials. If you see a permissions violation for `$JS.API.*`, re-run with a privileged user to provision or set `auto_provision=false` and pre-create the stream/consumer first.

---

## Option A: Provision with the built-in task (creates stream + consumer)

Run this from CI/deploy with admin NATS credentials:

```bash
# Uses your configured stream/app/destination to create the stream + durable consumer
NATS_URLS="nats://admin:pass@nats.example.com:4222" \
bundle exec rake jetstream_bridge:provision
```

This is the easiest way to keep `auto_provision=false` in runtime while still reusing the bridge’s topology logic (subjects, DLQ, overlap guard).

## Option B: Pre-create Consumers using NATS CLI

### Install NATS CLI

```bash
# Download from https://github.com/nats-io/natscli/releases
curl -sf https://binaries.nats.dev/nats-io/natscli/nats@latest | sh

# Or using Homebrew (macOS)
brew install nats-io/nats-tools/nats
```

### Create Pull Consumer (Default Mode)

You need to create a durable pull consumer with the exact configuration your app expects. Both apps share a single stream; create one consumer per app (each filters the opposite direction).

**Required values from your JetStream Bridge config:**

- **Stream name**: `JETSTREAM_STREAM_NAME` (e.g., `pwas-heavyworth-sync`)
- **Consumer name**: `{app_name}-workers` (e.g., `pwas-workers`)
- **Filter subject**: `{destination_app}.sync.{app_name}` (e.g., `heavyworth.sync.pwas`)

**Create pull consumer command:**

```bash
# Connect using a privileged NATS account
nats context save admin \
  --server=nats://admin-user:admin-pass@nats.example.com:4222 \
  --description="Admin account for consumer creation"

# Select the context
nats context select admin

# Create the consumer (replace stream/app/destination with yours)
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
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
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000
```

### Create Push Consumer (For Restricted Permissions)

Push consumers don't require JetStream API permissions at runtime. Messages are delivered to a subscription subject that the app can subscribe to based on its existing permissions.

**Required values:**

- **Stream name**: `JETSTREAM_STREAM_NAME` (e.g., `pwas-heavyworth-sync`)
- **Consumer name**: `{app_name}-workers` (e.g., `pwas-workers`)
- **Filter subject**: `{destination_app}.sync.{app_name}` (e.g., `heavyworth.sync.pwas`)
- **Delivery subject**: Subject the app can subscribe to (e.g., `heavyworth.sync.pwas.worker`)

**Create push consumer command:**

```bash
# For pwas app (receives heavyworth -> pwas messages)
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
  --deliver "heavyworth.sync.pwas.worker" \
  --ack explicit \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000
```

**Key difference:** The `--deliver` flag specifies where messages are pushed. The app subscribes to this subject directly, without calling `$JS.API.CONSUMER.MSG.NEXT.*`.

**Example using your observed stream (`pwas-heavyworth-sync`) and defaults (shared stream, two consumers):**

```bash
# Admin context
nats context save admin \
  --server=nats://admin-user:admin-pass@nats.example.com:4222 \
  --description="Admin account for jetstream_bridge provisioning"
nats context select admin

# Create stream with bridge subjects + DLQ
nats stream add pwas-heavyworth-sync \
  --subjects "pwas.sync.heavyworth" "heavyworth.sync.pwas" "pwas.sync.dlq" \
  --retention workqueue \
  --storage file

# Create durable pull consumer (must match JetstreamBridge config)
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000

# Consumer for heavyworth (receives pwas -> heavyworth)
nats consumer add pwas-heavyworth-sync heavyworth-workers \
  --filter "pwas.sync.heavyworth" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000

# Verify
nats stream info pwas-heavyworth-sync
nats consumer info pwas-heavyworth-sync heavyworth-workers
nats consumer info pwas-heavyworth-sync pwas-workers
```

### Provision both apps (shared stream + two consumers)

If both apps share one stream, create it once and add a durable consumer for each side:

```bash
STREAM="appA-appB-sync"
APP_A="appA" # first app name
APP_B="appB" # second app name

# Admin context (update server/creds as needed)
nats context save admin \
  --server=nats://admin-user:admin-pass@nats.example.com:4222 \
  --description="Admin account for jetstream_bridge provisioning"
nats context select admin

# Stream covers both publish directions + both DLQs
nats stream add "$STREAM" \
  --subjects "$APP_A.sync.$APP_B" "$APP_B.sync.$APP_A" "$APP_A.sync.dlq" "$APP_B.sync.dlq" \
  --retention workqueue \
  --storage file

# Consumer for APP_A (receives messages destined to APP_A)
nats consumer add "$STREAM" "$APP_A-workers" \
  --filter "$APP_B.sync.$APP_A" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000

# Consumer for APP_B (receives messages destined to APP_B)
nats consumer add "$STREAM" "$APP_B-workers" \
  --filter "$APP_A.sync.$APP_B" \
  --ack explicit \
  --pull \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000

# Verify both
nats consumer info "$STREAM" "$APP_A-workers"
nats consumer info "$STREAM" "$APP_B-workers"
```

### Verify Consumer Creation

```bash
nats consumer info pwas-heavyworth-sync pwas-workers
```

Expected output:

```bash
Information for Consumer pwas-heavyworth-sync > pwas-workers

Configuration:

        Durable Name: pwas-workers
      Filter Subject: heavyworth.sync.pwas
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
  config.stream_name = "pwas-heavyworth-sync"
  config.app_name = "pwas"
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

Use the published gem in your application (no local path):

```ruby
# Gemfile
gem "jetstream_bridge", "~> 7.0"
```

Then update:

```bash
bundle update jetstream_bridge
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
INFO -- : [DataSync] Consumer starting (durable=pwas-workers, batch=25, dest="heavyworth")
INFO -- : [DataSync] run! started successfully
```

Health checks will report connectivity only when `auto_provision=false` (stream info is skipped to avoid `$JS.API.STREAM.INFO`).

**If you still see errors:**

1. **Timeout during subscribe** - The pre-created consumer name/filter might not match. Verify:

   ```bash
   nats consumer ls pwas-heavyworth-sync
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
   nats consumer rm pwas-heavyworth-sync pwas-workers -f
   ```

3. **Create the new consumer** with updated settings

    ```bash
    nats consumer add pwas-heavyworth-sync pwas-workers \
      --filter "heavyworth.sync.pwas" \
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
nats stream info pwas-heavyworth-sync
```

**Verify filter subject matches your topology:**

```bash
# App publishes to:   {app_name}.sync.{destination_app}
# Consumer filters on: {destination_app}.sync.{app_name}
```

### Service keeps restarting

Check if the issue is:

1. **Stream doesn't exist** - Provision it with NATS CLI or admin credentials (consumers are auto-created)
2. **Filter subject mismatch** - Verify with `nats consumer info`
3. **Permissions still insufficient** - User needs subscribe permissions on the filtered subject
4. **Wrong stream name** - Ensure stream name matches your configured `config.stream_name`

**Note (v7.1.0+):** Consumers are auto-created if they don't exist, so "consumer doesn't exist" is no longer a common cause. However, the **stream must exist** or you'll see `StreamNotFoundError`.

---

## Security Considerations

1. **Stream pre-creation requires privileged access** - Keep admin credentials secure
2. **Configuration drift risk** - If app config doesn't match consumer config, message delivery may fail silently
3. **Automatic consumer recovery (v7.1.0+)** - If consumer is deleted, it will be auto-recreated on subscription. Stream must exist.
4. **Consider automation** - Use infrastructure-as-code (Terraform, Ansible) to manage stream creation

---

## Example: Production Setup for pwas-api

Based on your logs and permission requirements, here's the recommended setup using **push consumers** (no JetStream API permissions needed):

```bash
# 1. Provision stream and both push consumers (as admin)
nats stream add pwas-heavyworth-sync \
  --subjects "pwas.sync.heavyworth" "heavyworth.sync.pwas" "pwas.sync.dlq" "heavyworth.sync.dlq" \
  --retention workqueue \
  --storage file

# Push consumer for pwas (receives heavyworth -> pwas)
# Delivers to heavyworth.sync.pwas.worker (pwas can subscribe to heavyworth.*)
nats consumer add pwas-heavyworth-sync pwas-workers \
  --filter "heavyworth.sync.pwas" \
  --deliver "heavyworth.sync.pwas.worker" \
  --ack explicit \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000

# Push consumer for heavyworth (receives pwas -> heavyworth)
# Delivers to pwas.sync.heavyworth.worker (heavyworth can subscribe to pwas.*)
nats consumer add pwas-heavyworth-sync heavyworth-workers \
  --filter "pwas.sync.heavyworth" \
  --deliver "pwas.sync.heavyworth.worker" \
  --ack explicit \
  --deliver all \
  --max-deliver 5 \
  --ack-wait 30s \
  --backoff 1s,5s,15s,30s,60s \
  --replay instant \
  --max-pending 25000
```

```ruby
# 2. Update config/initializers/jetstream_bridge.rb (pwas app)
JetstreamBridge.configure do |config|
  config.nats_urls = ENV.fetch("NATS_URLS") # e.g., nats://pwas:***@10.199.12.34:4222
  config.stream_name = "pwas-heavyworth-sync"
  config.app_name = "pwas"
  config.destination_app = "heavyworth"
  config.auto_provision = false

  # Enable push consumer mode (no JetStream API permissions needed)
  config.consumer_mode = :push
  config.delivery_subject = "heavyworth.sync.pwas.worker"

  config.max_deliver = 5
  config.ack_wait = "30s"
  config.backoff = %w[1s 5s 15s 30s 60s]
end
```

```ruby
# 3. Update config/initializers/jetstream_bridge.rb (heavyworth app)
JetstreamBridge.configure do |config|
  config.nats_urls = ENV.fetch("NATS_URLS") # e.g., nats://heavyworth:***@10.199.12.34:4222
  config.stream_name = "pwas-heavyworth-sync"
  config.app_name = "heavyworth"
  config.destination_app = "pwas"
  config.auto_provision = false

  # Enable push consumer mode
  config.consumer_mode = :push
  config.delivery_subject = "pwas.sync.heavyworth.worker"

  config.max_deliver = 5
  config.ack_wait = "30s"
  config.backoff = %w[1s 5s 15s 30s 60s]
end
```

**NATS Permissions:**

```conf
# pwas user
publish: { allow: ["pwas.>", "$JS.ACK.pwas-heavyworth-sync.pwas-workers.>"] }
subscribe: { allow: ["heavyworth.>"] }

# heavyworth user
publish: { allow: ["heavyworth.>", "$JS.ACK.pwas-heavyworth-sync.heavyworth-workers.>"] }
subscribe: { allow: ["pwas.>"] }
```

**Note:** With push consumers, no `$JS.API.*` or `_INBOX.>` permissions are required. The `$JS.ACK` permission is needed so the consumer can acknowledge (ack/nak) delivered messages.

---

## Summary: Permission Requirements by Consumer Mode

If you have any influence over NATS permissions, you have two options:

### Option 1: Pull Consumers (Default) - Summary

Request minimal JetStream API permissions:

```conf
# Minimal permissions needed for pull consumer (e.g., pwas user)
publish: {
  allow: [
    "pwas.>",                                                          # Your app subjects
    "$JS.API.CONSUMER.MSG.NEXT.pwas-heavyworth-sync.pwas-workers",    # Fetch messages (required)
    "$JS.ACK.pwas-heavyworth-sync.pwas-workers.>",                    # Ack/nak messages (required)
  ]
}
subscribe: {
  allow: [
    "heavyworth.>",                        # Destination app subjects
    "_INBOX.>",                            # Request-reply responses (required)
  ]
}
```

These are read-only operations and don't allow creating/modifying streams or consumers.

### Option 2: Push Consumers (Recommended)

Use push consumers with business subject permissions plus ack:

```conf
# For pwas app
publish: { allow: ["pwas.>", "$JS.ACK.pwas-heavyworth-sync.pwas-workers.>"] }
subscribe: { allow: ["heavyworth.>"] }

# For heavyworth app
publish: { allow: ["heavyworth.>", "$JS.ACK.pwas-heavyworth-sync.heavyworth-workers.>"] }
subscribe: { allow: ["pwas.>"] }
```

**No `$JS.API.*` or `_INBOX.>` permissions required!** The only extra permission beyond business subjects is `$JS.ACK` for acknowledging messages.
