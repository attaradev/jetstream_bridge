# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/test_helpers'

RSpec.describe 'Mock Connection Integration', :allow_real_connection do
  include JetstreamBridge::TestHelpers

  before do
    # Reset singleton to ensure clean state
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
    JetstreamBridge.reset!

    # Enable test mode with mock NATS
    JetstreamBridge::TestHelpers.enable_test_mode!

    JetstreamBridge.configure do |config|
      config.nats_urls = 'nats://localhost:4222'
      config.env = 'test'
      config.app_name = 'test_app'
      config.destination_app = 'test_dest'
    end
  end

  after do
    JetstreamBridge::TestHelpers.reset_test_mode!
    JetstreamBridge::Connection.instance_variable_set(:@singleton__instance__, nil)
  end

  it 'uses mock connection when calling Connection.connect!' do
    # Setup mock stream
    mock_conn = JetstreamBridge::TestHelpers.mock_connection
    mock_jts = mock_conn.jetstream
    mock_jts.add_stream(
      name: 'test-jetstream-bridge-stream',
      subjects: ['test.>']
    )

    # Stub topology check
    allow(JetstreamBridge::Topology).to receive(:ensure!)

    # Connect through Connection class
    jts = JetstreamBridge::Connection.connect!

    # Verify we got the mock JetStream context
    expect(jts).to eq(mock_jts)
    expect(JetstreamBridge::Connection.instance.connected?).to be true
  end

  it 'publishes through JetstreamBridge.publish with mock' do
    # Setup mock stream
    mock_conn = JetstreamBridge::TestHelpers.mock_connection
    mock_jts = mock_conn.jetstream
    mock_jts.add_stream(
      name: 'test-jetstream-bridge-stream',
      subjects: ['test.>']
    )

    # Stub topology check
    allow(JetstreamBridge::Topology).to receive(:ensure!)

    # Publish event
    result = JetstreamBridge.publish(
      event_type: 'user.created',
      resource_type: 'user',
      payload: { id: 1, name: 'Test User' }
    )

    # Verify publish succeeded
    expect(result.success?).to be true
    expect(result.event_id).to be_a(String)
    expect(result.subject).to eq('test.test_app.sync.test_dest')
    expect(result.duplicate?).to be false

    # Verify message in storage
    storage = JetstreamBridge::TestHelpers.mock_storage
    expect(storage.messages.size).to eq(1)

    message = storage.messages.first
    expect(message[:subject]).to eq('test.test_app.sync.test_dest')

    envelope = Oj.load(message[:data])
    expect(envelope['event_type']).to eq('user.created')
    expect(envelope['payload']['name']).to eq('Test User')
  end

  it 'detects duplicate events with mock' do
    # Setup mock stream
    mock_conn = JetstreamBridge::TestHelpers.mock_connection
    mock_jts = mock_conn.jetstream
    mock_jts.add_stream(
      name: 'test-jetstream-bridge-stream',
      subjects: ['test.>']
    )

    # Stub topology check
    allow(JetstreamBridge::Topology).to receive(:ensure!)

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

    expect(result1.success?).to be true
    expect(result1.duplicate?).to be false

    expect(result2.success?).to be true
    expect(result2.duplicate?).to be true

    # Verify only one message in storage
    storage = JetstreamBridge::TestHelpers.mock_storage
    expect(storage.messages.size).to eq(1)
  end

  it 'works without NATS server running' do
    # This test verifies that the mock completely replaces the need for NATS

    # Setup mock stream
    mock_conn = JetstreamBridge::TestHelpers.mock_connection
    mock_jts = mock_conn.jetstream
    mock_jts.add_stream(
      name: 'test-jetstream-bridge-stream',
      subjects: ['test.>']
    )

    # Stub topology check
    allow(JetstreamBridge::Topology).to receive(:ensure!)

    # This would fail with a real NATS connection if server isn't running
    expect do
      result = JetstreamBridge.publish(
        event_type: 'test.event',
        resource_type: 'test',
        payload: { test: true }
      )
      expect(result.success?).to be true
    end.not_to raise_error
  end
end
