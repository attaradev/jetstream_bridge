# Testing with Mock NATS

JetstreamBridge provides a comprehensive in-memory mock for NATS JetStream that allows you to test your application without requiring a real NATS server.

## Overview

The mock NATS implementation simulates:

- NATS connection lifecycle (connect, disconnect, reconnect)
- JetStream publish/subscribe operations
- Message acknowledgment (ACK, NAK, TERM)
- Consumer durable state and message redelivery
- Duplicate message detection
- Stream and consumer management
- Error scenarios

## Basic Usage

### With Test Helpers (Recommended)

The easiest way to use the mock is through the test helpers. The mock automatically integrates with the Connection class, so no additional mocking is needed:

```ruby
require 'jetstream_bridge/test_helpers'

RSpec.describe MyService do
  include JetstreamBridge::TestHelpers
  include JetstreamBridge::TestHelpers::Matchers

  before do
    # Reset singleton to ensure clean state
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
    JetstreamBridge.reset!

    # Enable test mode - automatically sets up mock NATS
    JetstreamBridge::TestHelpers.enable_test_mode!

    JetstreamBridge.configure do |config|
      config.stream_name = 'jetstream-bridge-stream'
      config.app_name = 'my_app'
      config.destination_app = 'worker'
    end

    # Setup mock stream and stub topology
    mock_jts = JetstreamBridge::TestHelpers.mock_connection.jetstream
    mock_jts.add_stream(
      name: 'test-jetstream-bridge-stream',
      subjects: ['test.>']
    )
    allow(JetstreamBridge::Topology).to receive(:ensure!)
  end

  after do
    JetstreamBridge::TestHelpers.reset_test_mode!
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
  end

  it 'publishes events through the full stack' do
    result = JetstreamBridge.publish(
      event_type: 'user.created',
      resource_type: 'user',
      payload: { id: 1, name: 'Ada' }
    )

    expect(result.success?).to be true
    expect(result.duplicate?).to be false

    # Can also use matchers (requires test mode)
    expect(JetstreamBridge).to have_published(
      event_type: 'user.created',
      payload: hash_including(name: 'Ada')
    )
  end
end
```

### Manual Mock Setup

For more control, you can manually set up the mock:

```ruby
require 'jetstream_bridge/test_helpers/mock_nats'

RSpec.describe 'Publishing' do
  let(:mock_connection) { JetstreamBridge::TestHelpers::MockNats.create_mock_connection }
  let(:jetstream) { mock_connection.jetstream }

  before do
    mock_connection.connect
    allow(NATS::IO::Client).to receive(:new).and_return(mock_connection)
  end

  it 'publishes a message' do
    ack = jetstream.publish(
      'test.subject',
      { user_id: 1 }.to_json,
      header: { 'nats-msg-id' => 'unique-id' }
    )

    expect(ack.duplicate?).to be false
    expect(ack.sequence).to eq(1)
  end
end
```

## Features

### Publishing Events

The mock tracks all published messages and supports duplicate detection:

```ruby
mock_jts = mock_connection.jetstream

# First publish
ack1 = mock_jts.publish('subject', data, header: { 'nats-msg-id' => 'id-1' })
expect(ack1.duplicate?).to be false

# Duplicate publish
ack2 = mock_jts.publish('subject', data, header: { 'nats-msg-id' => 'id-1' })
expect(ack2.duplicate?).to be true
```

### Consuming Events

Create subscriptions and fetch messages:

```ruby
# Publish messages
3.times do |i|
  jetstream.publish(
    'test.subject',
    { msg: i }.to_json,
    header: { 'nats-msg-id' => "msg-#{i}" }
  )
end

# Subscribe and fetch
subscription = jetstream.pull_subscribe('test.subject', 'consumer', stream: 'test-stream')
messages = subscription.fetch(10, timeout: 1)

expect(messages.size).to eq(3)

# Process and acknowledge
messages.each do |msg|
  data = Oj.load(msg.data)
  process(data)
  msg.ack
end
```

### Message Acknowledgment

The mock supports all acknowledgment types:

```ruby
message = subscription.fetch(1).first

# Positive acknowledgment (removes from queue)
message.ack

# Negative acknowledgment (keeps in queue for redelivery)
message.nak

# Terminate (removes from queue without processing)
message.term
```

### Redelivery and max_deliver

The mock respects `max_deliver` settings:

```ruby
subscription = jetstream.pull_subscribe(
  'test.subject',
  'consumer',
  stream: 'test-stream',
  max_deliver: 3
)

# Publish a message
jetstream.publish('test.subject', 'data', header: { 'nats-msg-id' => 'id-1' })

# Attempt 1
msg = subscription.fetch(1).first
expect(msg.metadata.num_delivered).to eq(1)
msg.nak

# Attempt 2
msg = subscription.fetch(1).first
expect(msg.metadata.num_delivered).to eq(2)
msg.nak

# Attempt 3
msg = subscription.fetch(1).first
expect(msg.metadata.num_delivered).to eq(3)
msg.nak

# Attempt 4 - empty (exceeded max_deliver)
msgs = subscription.fetch(1)
expect(msgs).to be_empty
```

### Stream and Consumer Management

```ruby
# Add a stream
jetstream.add_stream(
  name: 'my-stream',
  subjects: ['my.subject.>']
)

# Get stream info
info = jetstream.stream_info('my-stream')
expect(info.config.name).to eq('my-stream')

# Get consumer info
subscription = jetstream.pull_subscribe('my.subject', 'consumer', stream: 'my-stream')
info = jetstream.consumer_info('my-stream', 'consumer')
expect(info.name).to eq('consumer')
```

### Connection Lifecycle

Simulate connection events:

```ruby
mock_connection = JetstreamBridge::TestHelpers::MockNats.create_mock_connection

# Register callbacks
reconnect_called = false
mock_connection.on_reconnect { reconnect_called = true }

# Simulate events
mock_connection.simulate_disconnect!
expect(mock_connection.connected?).to be false

mock_connection.simulate_reconnect!
expect(reconnect_called).to be true
```

### Error Scenarios

The mock can simulate various error conditions:

```ruby
# JetStream not available
disconnected_conn = JetstreamBridge::TestHelpers::MockNats.create_mock_connection
expect { disconnected_conn.jetstream }.to raise_error(NATS::IO::NoRespondersError)

# Stream not found
expect do
  jetstream.stream_info('nonexistent')
end.to raise_error(NATS::JetStream::Error, 'stream not found')

# Consumer not found
expect do
  jetstream.consumer_info('test-stream', 'nonexistent')
end.to raise_error(NATS::JetStream::Error, 'consumer not found')
```

## Integration with JetstreamBridge

### Full Publishing Flow

```ruby
before do
  JetstreamBridge.reset!

  mock_conn = JetstreamBridge::TestHelpers::MockNats.create_mock_connection
  mock_jts = mock_conn.jetstream

  allow(NATS::IO::Client).to receive(:new).and_return(mock_conn)
  allow(JetstreamBridge::Connection).to receive(:connect!).and_call_original

  # Setup stream
  mock_jts.add_stream(
    name: 'test-jetstream-bridge-stream',
    subjects: ['test.>']
  )

  # Allow topology check to succeed
  allow(JetstreamBridge::Topology).to receive(:ensure!)

  JetstreamBridge.configure do |config|
    config.stream_name = 'jetstream-bridge-stream'
    config.app_name = 'api'
    config.destination_app = 'worker'
  end
end

it 'publishes through JetstreamBridge' do
  result = JetstreamBridge.publish(
    event_type: 'user.created',
    resource_type: 'user',
    payload: { id: 1, name: 'Test' }
  )

  expect(result).to be_publish_success
  expect(result.event_id).to be_present
   expect(result.subject).to eq('api.sync.worker')

  # Verify in storage
  storage = JetstreamBridge::TestHelpers.mock_storage
  expect(storage.messages.size).to eq(1)
end
```

### Full Consuming Flow

```ruby
it 'consumes through JetstreamBridge' do
  mock_conn = JetstreamBridge::TestHelpers.mock_connection
  mock_jts = mock_conn.jetstream

  # Publish message to destination subject
  mock_jts.publish(
    'worker.sync.api',
    Oj.dump({
      'event_id' => 'event-1',
      'schema_version' => 1,
      'event_type' => 'task.created',
      'producer' => 'api',
      'resource_id' => '1',
      'resource_type' => 'task',
      'occurred_at' => Time.now.utc.iso8601,
      'trace_id' => SecureRandom.hex(8),
      'payload' => { id: 1, title: 'Task 1' }
    }),
    header: { 'nats-msg-id' => 'event-1' }
  )

  # Create consumer
  events_received = []
  consumer = JetstreamBridge::Consumer.new(batch_size: 10) do |event|
    events_received << event
  end

  # Mock subscription
  subscription = mock_jts.pull_subscribe(
    'worker.sync.api',
    'test-consumer',
    stream: 'test-jetstream-bridge-stream'
  )

  allow_any_instance_of(JetstreamBridge::SubscriptionManager)
    .to receive(:subscribe!)
    .and_return(subscription)

  # Process one batch
  allow(consumer).to receive(:stop_requested?).and_return(false, true)
  consumer.run!

  expect(events_received.size).to eq(1)
  expect(events_received.first.type).to eq('task.created')
end
```

## Direct Storage Access

For advanced testing, you can access the mock storage directly:

```ruby
storage = JetstreamBridge::TestHelpers.mock_storage

# Inspect all messages
storage.messages.each do |msg|
  puts "Subject: #{msg[:subject]}"
  puts "Data: #{msg[:data]}"
  puts "Delivery count: #{msg[:delivery_count]}"
end

# Check streams
storage.streams.each do |name, stream|
  puts "Stream: #{name}"
end

# Check consumers
storage.consumers.each do |name, consumer|
  puts "Consumer: #{name} on stream #{consumer.stream}"
end

# Reset storage
storage.reset!
```

## Best Practices

1. **Reset state between tests**: Always call `reset_test_mode!` in your `after` hooks
2. **Use test helpers when possible**: They handle most of the mocking setup for you
3. **Test both success and failure paths**: Use the mock to simulate errors
4. **Verify message content**: Check that envelopes are correctly formatted
5. **Test idempotency**: Verify duplicate detection and redelivery behavior
6. **Mock topology setup**: Remember to stub `JetstreamBridge::Topology.ensure!`

## Examples

See the comprehensive test examples in:

- [spec/test_helpers/mock_nats_spec.rb](../spec/test_helpers/mock_nats_spec.rb)
- [spec/integration/mock_integration_spec.rb](../spec/integration/mock_integration_spec.rb)
- [spec/integration/mock_connection_integration_spec.rb](../spec/integration/mock_connection_integration_spec.rb)

## Limitations

The mock is designed for testing and has some simplifications:

- No actual network operations
- Simplified stream subject matching (uses first stream)
- No persistent storage between test runs
- Simplified timing/timeout behavior
- No cluster or failover simulation

For integration tests that require a real NATS server, consider using Docker to run NATS in CI/CD environments.
