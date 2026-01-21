# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/test_helpers'

RSpec.describe 'Mock NATS Integration Examples', :allow_real_connection do
  include JetstreamBridge::TestHelpers
  include JetstreamBridge::TestHelpers::Matchers

  before do
    # Reset singleton to ensure clean state between examples
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
    JetstreamBridge.reset!
    JetstreamBridge::TestHelpers.enable_test_mode!

    JetstreamBridge.configure do |config|
      config.nats_urls = 'nats://localhost:4222'
      config.app_name = 'api'
      config.destination_app = 'worker'
      config.stream_name = 'test-jetstream-bridge-stream'
    end
  end

  after do
    JetstreamBridge::TestHelpers.reset_test_mode!
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
  end

  describe 'publishing events with mock' do
    it 'publishes events without a real NATS server' do
      # Get the mock connection
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      # Allow Connection to return our mock
      allow(JetstreamBridge::Connection).to receive(:connect!).and_return(mock_conn)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(mock_jts)

      # Setup stream
      mock_jts.add_stream(
        name: 'test-jetstream-bridge-stream',
        subjects: ['test.>']
      )

      # Publish an event
      result = JetstreamBridge.publish(
        event_type: 'user.created',
        resource_type: 'user',
        payload: { id: 1, name: 'Ada Lovelace', email: 'ada@example.com' }
      )

      expect(result).to be_publish_success
      expect(result.event_id).to be_a(String)
      expect(result.subject).to eq('api.sync.worker')

      # Verify message was stored in mock
      storage = JetstreamBridge::TestHelpers.mock_storage
      expect(storage.messages.size).to eq(1)

      message = storage.messages.first
      envelope = Oj.load(message[:data])
      expect(envelope['event_type']).to eq('user.created')
      expect(envelope['payload']['name']).to eq('Ada Lovelace')
    end

    it 'detects duplicate events' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      allow(JetstreamBridge::Connection).to receive(:connect!).and_return(mock_conn)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(mock_jts)

      event_id = SecureRandom.uuid

      # Publish same event twice
      result1 = JetstreamBridge.publish(
        event_type: 'user.created',
        resource_type: 'user',
        payload: { id: 1 },
        event_id: event_id
      )

      result2 = JetstreamBridge.publish(
        event_type: 'user.created',
        resource_type: 'user',
        payload: { id: 1 },
        event_id: event_id
      )

      expect(result1).to be_publish_success
      expect(result1.duplicate?).to be false

      expect(result2).to be_publish_success
      expect(result2.duplicate?).to be true
    end
  end

  describe 'consuming events with mock' do
    it 'verifies mock subscription behavior' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      # Setup stream
      mock_jts.add_stream(
        name: 'test-jetstream-bridge-stream',
        subjects: ['test.>']
      )

      # Publish messages
      3.times do |i|
        mock_jts.publish(
          'test.worker.sync.api',
          Oj.dump({
                    'event_id' => "event-#{i}",
                    'schema_version' => 1,
                    'event_type' => 'task.created',
                    'producer' => 'api',
                    'resource_id' => (i + 1).to_s,
                    'resource_type' => 'task',
                    'occurred_at' => Time.now.utc.iso8601,
                    'trace_id' => SecureRandom.hex(8),
                    'payload' => { 'id' => i + 1, 'title' => "Task #{i + 1}" }
                  }),
          header: { 'nats-msg-id' => "event-#{i}" }
        )
      end

      # Create subscription and fetch messages directly
      subscription = mock_jts.pull_subscribe(
        'test.worker.sync.api',
        'test-consumer',
        stream: 'test-jetstream-bridge-stream'
      )

      # Verify we can fetch the messages
      messages = subscription.fetch(10, timeout: 1)
      expect(messages.size).to eq(3)

      # Verify message content
      envelope = Oj.load(messages[0].data)
      expect(envelope['event_type']).to eq('task.created')
      expect(envelope['payload']['title']).to eq('Task 1')

      # Acknowledge messages
      messages.each(&:ack)

      # Verify messages are acknowledged
      messages_after_ack = subscription.fetch(1, timeout: 1)
      expect(messages_after_ack).to be_empty
    end

    it 'handles message acknowledgment' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      # Publish a message
      mock_jts.publish(
        'test.subject',
        Oj.dump({ 'event_id' => 'test-1', 'event_type' => 'test.event', 'payload' => {} }),
        header: { 'nats-msg-id' => 'test-1' }
      )

      # Create subscription and fetch message
      subscription = mock_jts.pull_subscribe('test.subject', 'test-consumer', stream: 'test-stream')
      messages = subscription.fetch(1, timeout: 1)

      expect(messages.size).to eq(1)

      # Acknowledge the message
      messages.first.ack

      # Try to fetch again - should be empty
      messages_after_ack = subscription.fetch(1, timeout: 1)
      expect(messages_after_ack).to be_empty
    end

    it 'handles message redelivery on NAK' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      # Publish a message
      mock_jts.publish(
        'test.subject',
        Oj.dump({ 'event_id' => 'test-1', 'event_type' => 'test.event', 'payload' => {} }),
        header: { 'nats-msg-id' => 'test-1' }
      )

      # Create subscription with max_deliver
      subscription = mock_jts.pull_subscribe(
        'test.subject',
        'test-consumer',
        stream: 'test-stream',
        max_deliver: 3
      )

      # First attempt
      messages = subscription.fetch(1, timeout: 1)
      expect(messages.size).to eq(1)
      expect(messages.first.metadata.num_delivered).to eq(1)
      messages.first.nak

      # Second attempt
      messages = subscription.fetch(1, timeout: 1)
      expect(messages.size).to eq(1)
      expect(messages.first.metadata.num_delivered).to eq(2)
      messages.first.nak

      # Third attempt
      messages = subscription.fetch(1, timeout: 1)
      expect(messages.size).to eq(1)
      expect(messages.first.metadata.num_delivered).to eq(3)
      messages.first.nak

      # Fourth attempt - should be empty (exceeded max_deliver)
      messages = subscription.fetch(1, timeout: 1)
      expect(messages).to be_empty
    end
  end

  describe 'end-to-end publish and consume' do
    it 'publishes and consumes through the full stack' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_jts = mock_conn.jetstream

      # Setup stream
      mock_jts.add_stream(
        name: 'test-jetstream-bridge-stream',
        subjects: ['test.>']
      )

      # Allow topology to succeed
      allow(JetstreamBridge::Topology).to receive(:ensure!)

      # Connect (this will auto-connect when we publish, but we can also call it explicitly)
      JetstreamBridge.connect!

      # Publish from API to Worker
      result = JetstreamBridge.publish(
        event_type: 'user.created',
        resource_type: 'user',
        payload: { id: 42, name: 'Test User' }
      )

      expect(result).to be_publish_success

      # Now simulate consuming on the worker side
      # Messages published to 'api.sync.worker' should be consumed from 'worker.sync.api'
      # For this test, we'll directly verify the message is in storage
      storage = JetstreamBridge::TestHelpers.mock_storage
      expect(storage.messages.size).to eq(1)

      message = storage.messages.first
      expect(message[:subject]).to eq('api.sync.worker')

      envelope = Oj.load(message[:data])
      expect(envelope['event_type']).to eq('user.created')
      expect(envelope['payload']['id']).to eq(42)
    end
  end

  describe 'error scenarios' do
    it 'handles connection errors' do
      # Create a fresh unconnected mock
      mock_conn = JetstreamBridge::TestHelpers::MockNats.create_mock_connection

      # Don't connect - verify jetstream raises error when not connected
      expect { mock_conn.jetstream }.to raise_error(NATS::IO::NoRespondersError)
    end

    it 'handles stream not found errors' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_conn.connect
      mock_jts = mock_conn.jetstream

      expect do
        mock_jts.stream_info('nonexistent-stream')
      end.to raise_error(NATS::JetStream::Error, 'stream not found')
    end

    it 'handles consumer not found errors' do
      mock_conn = JetstreamBridge::TestHelpers.mock_connection
      mock_conn.connect
      mock_jts = mock_conn.jetstream

      expect do
        mock_jts.consumer_info('test-stream', 'nonexistent-consumer')
      end.to raise_error(NATS::JetStream::Error, 'consumer not found')
    end
  end
end
