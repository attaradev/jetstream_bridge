# Production Deployment Guide

This guide provides recommendations for deploying JetStream Bridge in production environments with a focus on reliability, security, and performance.

## Table of Contents

- [Database Connection Pool Sizing](#database-connection-pool-sizing)
- [NATS Connection Configuration](#nats-connection-configuration)
- [Consumer Tuning](#consumer-tuning)
- [Monitoring & Alerting](#monitoring--alerting)
- [Security Hardening](#security-hardening)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Performance Optimization](#performance-optimization)

---

## Database Connection Pool Sizing

JetStream Bridge uses ActiveRecord for outbox/inbox patterns. Proper connection pool sizing is critical for high-throughput applications.

### Recommended Configuration

```ruby
# config/database.yml
production:
  adapter: postgresql
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5).to_i + 10 %>
  timeout: 5000
  # Add buffer connections beyond web workers for consumer processes
```

### Sizing Guidelines

**Publishers (Web/API processes):**

- 1-2 connections per process (uses existing AR pool)
- Example: 4 Puma workers × 5 threads = 20 connections minimum

**Consumers:**

- Dedicated connections per consumer process
- Recommended: 2-5 connections per consumer
- Example: 3 consumer processes = 6-15 connections

**Total Formula:**

```markdowb
Total Connections = (Web Workers × Threads) + (Consumers × 3) + 10 buffer
```

### Example Calculation

For a typical production setup:

- 4 Puma workers × 5 threads = 20 connections
- 3 consumer processes × 3 connections = 9 connections
- 10 connection buffer = 10 connections
- **Total: 39 connections**

Set your PostgreSQL `max_connections` to at least 50-60 to allow headroom.

---

## NATS Connection Configuration

### High Availability Setup

Configure multiple NATS servers for fault tolerance:

```ruby
# config/initializers/jetstream_bridge.rb
JetstreamBridge.configure do |config|
  # Use cluster URLs for HA
  config.nats_urls = "nats://nats1:4222,nats://nats2:4222,nats://nats3:4222"

  # Adjust reconnect settings for production
  config.connect_retry_attempts = 5  # Default: 3
  config.connect_retry_delay = 3     # Default: 2 seconds

  # Required configuration
  config.env = ENV.fetch("RAILS_ENV", "production")
  config.app_name = ENV.fetch("APP_NAME", "myapp")
  config.destination_app = ENV.fetch("DESTINATION_APP")

  # Enable reliability features
  config.use_outbox = true
  config.use_inbox = true
  config.use_dlq = true
end
```

### TLS Configuration

For secure communications:

```ruby
JetstreamBridge.configure do |config|
  config.nats_urls = "nats+tls://nats:4222"
  # Ensure NATS server has TLS enabled with valid certificates
end
```

### Permissions and Inbox Prefix

JetStream API calls use request/reply and subscribe to an inbox subject. If your NATS account restricts `_INBOX.>` subscriptions, either grant the bridge user `_INBOX.>` subscribe permission **or** set an allowed prefix:

```ruby
JetstreamBridge.configure do |config|
  config.inbox_prefix = "$RPC" # choose a prefix permitted by your NATS account
end
```

If you pre-provision stream/consumer names, set:

```ruby
JetstreamBridge.configure do |config|
  config.stream_name = "my-stream"      # required
  config.durable_name = "my-durable"    # optional
end
```

If production clusters are isolated and you want env-less subjects instead of the default env-prefixed form:

```ruby
JetstreamBridge.configure do |config|
  # Default subjects: "#{app}.sync.#{dest}"
  config.stream_name = "my-stream" # required
end
```

Provision streams/subjects only when explicitly requested:

```ruby
JetstreamBridge.configure do |config|
  # Use explicit provisioning via JetstreamBridge.ensure_topology!
end

# Run provisioning when needed (e.g., deploy scripts/migrations):
# JetstreamBridge.ensure_topology!
```

Minimum permissions for the bridge user:

- Publish: `"$JS.API.>"`, `"$JS.ACK.>"`, your `source_subject` (`<env>.<app>.sync.<dest>`), your `destination_subject` (`<env>.<dest>.sync.<app>`), and the DLQ subject (`<env>.<app>.sync.dlq`) when DLQ is enabled.
- Subscribe: `_INBOX.>` (or your chosen `inbox_prefix` + `.>`), and your `destination_subject`.

If your security policy cannot allow any inbox subscriptions, pre-provision the stream and consumers and set:

```ruby
JetstreamBridge.configure do |config|
  # Default is true (management APIs skipped). Set to false if permissions allow JS management APIs.
  config.disable_js_api = false
end
```

When `disable_js_api` is true, JetstreamBridge will not perform JetStream management calls; ensure the stream, subjects, and consumers already exist and remain aligned with your configuration.

---

## Consumer Tuning

Optimize consumer configuration based on your workload:

### Basic Consumer Configuration

```ruby
JetstreamBridge.configure do |config|
  # Adjust batch size based on message processing time
  # Larger = better throughput, smaller = lower latency
  # Default: 25
  config.batch_size = 50

  # Increase max_deliver for critical messages
  # Default: 5
  config.max_deliver = 10

  # Adjust ack_wait for slow processors
  # Default: 30s
  config.ack_wait = "60s"

  # Configure exponential backoff delays
  # Default: [1s, 5s, 15s, 30s, 60s]
  config.backoff = %w[2s 10s 30s 60s 120s]
end
```

### Consumer Best Practices

1. **Run consumers in dedicated processes/containers** separate from web workers
2. **Scale horizontally** by running multiple consumer instances
3. **Monitor consumer lag** via NATS JetStream metrics
4. **Set appropriate resource limits** (CPU, memory) in Kubernetes/Docker

### Memory Management

Long-running consumers automatically:

- Log health checks every 10 minutes (iterations, memory, uptime)
- Warn when memory exceeds 1GB
- Warn once when heap object counts grow large so you can profile/trigger GC in the host app

Monitor these logs to detect memory leaks early.

---

## Monitoring & Alerting

### Key Metrics to Track

| Metric | Description | Alert Threshold |
| -------- | ------------- | ----------------- |
| Consumer Lag | Pending messages in stream | > 1000 messages |
| DLQ Size | Messages in dead letter queue | > 100 messages |
| Connection Status | Health check failures | 2 consecutive failures |
| Processing Rate | Messages/second throughput | < expected baseline |
| Memory Usage | Consumer memory consumption | > 1GB per consumer |
| Error Rate | Failed message processing | > 5% |

### Health Check Endpoint

Use the built-in health check for monitoring:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get '/health/jetstream', to: proc { |env|
    health = JetstreamBridge.health_check
    status = health[:healthy] ? 200 : 503
    [status, { 'Content-Type' => 'application/json' }, [health.to_json]]
  }
end
```

### Response Format

```json
{
  "healthy": true,
  "connection": {
    "state": "connected",
    "connected": true,
    "connected_at": "2025-11-23T10:00:00Z"
  },
  "stream": {
    "exists": true,
    "name": "production-jetstream-bridge-stream",
    "subjects": ["production.app.sync.worker"],
    "messages": 1523
  },
  "performance": {
    "nats_rtt_ms": 2.5,
    "health_check_duration_ms": 45.2
  },
  "config": {
    "env": "production",
    "app_name": "app",
    "destination_app": "worker",
    "use_outbox": true,
    "use_inbox": true,
    "use_dlq": true
  },
  "version": "4.0.3"
}
```

### Prometheus Metrics (Example)

```ruby
# config/initializers/prometheus.rb
require 'prometheus/client'

prometheus = Prometheus::Client.registry

# Track message processing
jetstream_messages = prometheus.counter(
  :jetstream_messages_total,
  docstring: 'Total messages processed',
  labels: [:status, :event_type]
)

# Track processing duration
jetstream_duration = prometheus.histogram(
  :jetstream_processing_duration_seconds,
  docstring: 'Message processing duration',
  labels: [:event_type]
)

# Track DLQ size
jetstream_dlq = prometheus.gauge(
  :jetstream_dlq_size,
  docstring: 'Messages in DLQ'
)
```

---

## Security Hardening

### Rate Limiting

The health check endpoint has built-in rate limiting (1 uncached request per 5 seconds). For HTTP endpoints, add additional protection:

```ruby
# Gemfile
gem 'rack-attack'

# config/initializers/rack_attack.rb
Rack::Attack.throttle('health_checks', limit: 30, period: 1.minute) do |req|
  req.ip if req.path == '/health/jetstream'
end
```

### Subject Validation

JetStream Bridge validates subject components to prevent injection attacks. The following are automatically rejected:

- NATS wildcards (`.`, `*`, `>`)
- Spaces and control characters
- Components exceeding 255 characters

### Credential Management

**Never hardcode credentials:**

```ruby
# ❌ BAD
config.nats_urls = "nats://user:password@localhost:4222"

# ✅ GOOD
config.nats_urls = ENV.fetch("NATS_URLS")
```

Credentials in logs are automatically sanitized:

- `nats://user:pass@host:4222` → `nats://user:***@host:4222`
- `nats://token@host:4222` → `nats://***@host:4222`

### Network Security

1. **Use TLS** for NATS connections in production
2. **Restrict network access** to NATS ports (4222) via firewall rules
3. **Use private networks** for inter-service communication
4. **Enable authentication** on NATS server

---

## Kubernetes Deployment

### Deployment Configuration

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jetstream-consumer
spec:
  replicas: 3
  selector:
    matchLabels:
      app: jetstream-consumer
  template:
    metadata:
      labels:
        app: jetstream-consumer
    spec:
      containers:
      - name: consumer
        image: myapp:latest
        command: ["bundle", "exec", "rake", "jetstream:consume"]
        env:
        - name: NATS_URLS
          valueFrom:
            secretKeyRef:
              name: nats-credentials
              key: urls
        - name: RAILS_ENV
          value: "production"
        - name: APP_NAME
          value: "myapp"
        - name: DESTINATION_APP
          value: "worker"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
            - pgrep
            - -f
            - "rake jetstream:consume"
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health/jetstream
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 5
```

### Health Probes

**Liveness Probe:** Checks if the consumer process is running

```yaml
livenessProbe:
  exec:
    command: ["pgrep", "-f", "jetstream:consume"]
  initialDelaySeconds: 30
  periodSeconds: 10
```

**Readiness Probe:** Checks if NATS connection is healthy

```yaml
readinessProbe:
  httpGet:
    path: /health/jetstream
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 5
```

### Horizontal Pod Autoscaling

```yaml
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: jetstream-consumer-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: jetstream-consumer
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

---

## Performance Optimization

### Database Query Optimization

1. **Add indexes** on frequently queried columns:

```sql
-- Outbox queries
CREATE INDEX idx_outbox_status_created ON jetstream_outbox_events(status, created_at);
CREATE INDEX idx_outbox_event_id ON jetstream_outbox_events(event_id);

-- Inbox queries
CREATE INDEX idx_inbox_event_id ON jetstream_inbox_events(event_id);
CREATE INDEX idx_inbox_stream_seq ON jetstream_inbox_events(stream, stream_seq);
CREATE INDEX idx_inbox_status ON jetstream_inbox_events(status);
```

1. **Partition large tables** (for high-volume applications):

```sql
-- Partition outbox by month
CREATE TABLE jetstream_outbox_events (
  -- columns
) PARTITION BY RANGE (created_at);

CREATE TABLE jetstream_outbox_events_2025_11
  PARTITION OF jetstream_outbox_events
  FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
```

1. **Archive old records** to prevent table bloat:

```ruby
# lib/tasks/jetstream_maintenance.rake
namespace :jetstream do
  desc "Archive old outbox events (older than 30 days)"
  task archive_outbox: :environment do
    cutoff = 30.days.ago
    JetstreamBridge::OutboxEvent.where('created_at < ?', cutoff)
                                 .where(status: 'sent')
                                 .in_batches
                                 .delete_all
  end
end
```

### NATS Optimization

1. **Use connection pooling** for high-throughput publishers
2. **Enable stream compression** for large payloads (NATS server config)
3. **Monitor stream storage** and set retention policies

### Consumer Optimization

1. **Increase batch size** for high-throughput scenarios (up to 100)
2. **Use multiple consumers** to parallelize processing
3. **Optimize handler code** to minimize per-message overhead
4. **Profile memory usage** with tools like `memory_profiler` gem

---

## Troubleshooting

### Common Issues

**High Consumer Lag:**

- Scale up consumer instances
- Increase batch size
- Optimize handler processing time
- Check database connection pool

**Memory Leaks:**

- Monitor consumer health logs
- Enable memory profiling
- Check for circular references in handlers
- Restart consumers periodically (Kubernetes handles this)

**Connection Issues:**

- Verify NATS server is accessible
- Check firewall rules
- Validate TLS certificates
- Review connection retry settings

**DLQ Growing:**

- Investigate failed message patterns
- Fix bugs in message handlers
- Increase max_deliver for transient errors
- Set up DLQ consumer for manual intervention

---

## Additional Resources

- [NATS JetStream Documentation](https://docs.nats.io/nats-concepts/jetstream)
- [PostgreSQL Connection Pooling](https://www.postgresql.org/docs/current/runtime-config-connection.html)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)
- [Prometheus Ruby Client](https://github.com/prometheus/client_ruby)

---

## Support

For issues or questions:

- GitHub Issues: <https://github.com/attaradev/jetstream_bridge/issues>
- Documentation: <https://github.com/attaradev/jetstream_bridge>
