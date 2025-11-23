# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/test_helpers'

RSpec.describe JetstreamBridge::TestHelpers::MockNats do
  let(:mock_connection) { described_class.create_mock_connection }
  let(:jetstream) { mock_connection.jetstream }

  before do
    described_class.reset!
    mock_connection.connect
  end

  describe 'MockConnection' do
    it 'starts disconnected' do
      fresh_connection = described_class.create_mock_connection
      expect(fresh_connection.connected?).to be false
    end

    it 'connects successfully' do
      expect(mock_connection.connected?).to be true
      expect(mock_connection.connected_at).to be_a(Time)
    end

    it 'provides jetstream context' do
      expect(mock_connection.jetstream).to be_a(JetstreamBridge::TestHelpers::MockNats::MockJetStream)
    end

    it 'raises error when accessing jetstream before connecting' do
      disconnected = described_class.create_mock_connection
      expect { disconnected.jetstream }.to raise_error(NATS::IO::NoRespondersError)
    end

    it 'registers callbacks' do
      reconnect_called = false
      disconnect_called = false
      error_received = nil

      mock_connection.on_reconnect { reconnect_called = true }
      mock_connection.on_disconnect { disconnect_called = true }
      mock_connection.on_error { |e| error_received = e }

      mock_connection.simulate_reconnect!
      expect(reconnect_called).to be true

      mock_connection.simulate_disconnect!
      expect(disconnect_called).to be true

      test_error = StandardError.new('test')
      mock_connection.simulate_error!(test_error)
      expect(error_received).to eq(test_error)
    end

    it 'provides round-trip time' do
      expect(mock_connection.rtt).to be > 0
    end
  end

  describe 'MockJetStream' do
    describe '#publish' do
      it 'publishes a message successfully' do
        data = { test: 'data' }.to_json
        header = { 'nats-msg-id' => 'test-id-123' }

        ack = jetstream.publish('test.subject', data, header: header)

        expect(ack).to be_a(JetstreamBridge::TestHelpers::MockNats::MockAck)
        expect(ack.duplicate?).to be false
        expect(ack.sequence).to eq(1)
        expect(ack.stream).to eq('mock-stream')
      end

      it 'detects duplicate messages' do
        data = { test: 'data' }.to_json
        header = { 'nats-msg-id' => 'duplicate-id' }

        ack1 = jetstream.publish('test.subject', data, header: header)
        ack2 = jetstream.publish('test.subject', data, header: header)

        expect(ack1.duplicate?).to be false
        expect(ack2.duplicate?).to be true
      end

      it 'generates unique event ID if not provided' do
        data = { test: 'data' }.to_json

        ack = jetstream.publish('test.subject', data, header: {})

        expect(ack.duplicate?).to be false
        expect(ack.sequence).to eq(1)
      end

      it 'increments sequence number' do
        3.times do |i|
          ack = jetstream.publish(
            'test.subject',
            { index: i }.to_json,
            header: { 'nats-msg-id' => "id-#{i}" }
          )
          expect(ack.sequence).to eq(i + 1)
        end
      end
    end

    describe '#pull_subscribe' do
      it 'creates a subscription' do
        subscription = jetstream.pull_subscribe(
          'test.subject',
          'test-consumer',
          stream: 'test-stream'
        )

        expect(subscription).to be_a(JetstreamBridge::TestHelpers::MockNats::MockSubscription)
        expect(subscription.durable_name).to eq('test-consumer')
        expect(subscription.subject).to eq('test.subject')
      end

      it 'allows fetching published messages' do
        jetstream.publish(
          'test.subject',
          { msg: 1 }.to_json,
          header: { 'nats-msg-id' => 'msg-1' }
        )
        jetstream.publish(
          'test.subject',
          { msg: 2 }.to_json,
          header: { 'nats-msg-id' => 'msg-2' }
        )

        subscription = jetstream.pull_subscribe('test.subject', 'consumer', stream: 'test-stream')
        messages = subscription.fetch(10, timeout: 1)

        expect(messages.size).to eq(2)
        expect(Oj.load(messages[0].data)['msg']).to eq(1)
        expect(Oj.load(messages[1].data)['msg']).to eq(2)
      end

      it 'respects batch size' do
        5.times do |i|
          jetstream.publish(
            'test.subject',
            { msg: i }.to_json,
            header: { 'nats-msg-id' => "msg-#{i}" }
          )
        end

        subscription = jetstream.pull_subscribe('test.subject', 'consumer', stream: 'test-stream')
        messages = subscription.fetch(2, timeout: 1)

        expect(messages.size).to eq(2)
      end

      it 'returns empty array when no messages available' do
        subscription = jetstream.pull_subscribe('test.subject', 'consumer', stream: 'test-stream')
        messages = subscription.fetch(10, timeout: 1)

        expect(messages).to be_empty
      end
    end

    describe '#account_info' do
      it 'returns account information' do
        info = jetstream.account_info

        expect(info.memory).to be > 0
        expect(info.storage).to be > 0
        expect(info.streams).to be >= 0
        expect(info.consumers).to be >= 0
      end
    end

    describe '#stream_info' do
      it 'raises error when stream not found' do
        expect do
          jetstream.stream_info('nonexistent')
        end.to raise_error(NATS::JetStream::Error, 'stream not found')
      end

      it 'returns stream info when stream exists' do
        jetstream.add_stream(name: 'test-stream', subjects: ['test.>'])
        info = jetstream.stream_info('test-stream')

        expect(info.config.name).to eq('test-stream')
        expect(info.config.subjects).to eq(['test.>'])
      end
    end

    describe '#consumer_info' do
      it 'raises error when consumer not found' do
        expect do
          jetstream.consumer_info('test-stream', 'nonexistent')
        end.to raise_error(NATS::JetStream::Error, 'consumer not found')
      end

      it 'returns consumer info when consumer exists' do
        jetstream.pull_subscribe('test.subject', 'test-consumer', stream: 'test-stream')
        info = jetstream.consumer_info('test-stream', 'test-consumer')

        expect(info.name).to eq('test-consumer')
        expect(info.stream_name).to eq('test-stream')
      end
    end
  end

  describe 'MockMessage' do
    let(:subscription) do
      jetstream.pull_subscribe('test.subject', 'consumer', stream: 'test-stream')
    end

    before do
      jetstream.publish(
        'test.subject',
        { test: 'data' }.to_json,
        header: { 'nats-msg-id' => 'msg-1' }
      )
    end

    let(:message) { subscription.fetch(1, timeout: 1).first }

    it 'provides message data' do
      expect(message.subject).to eq('test.subject')
      expect(message.data).to eq({ test: 'data' }.to_json)
      expect(message.header['nats-msg-id']).to eq('msg-1')
    end

    it 'provides metadata' do
      metadata = message.metadata

      expect(metadata.num_delivered).to eq(1)
      expect(metadata.stream).to eq('test-stream')
      expect(metadata.consumer).to eq('consumer')
      expect(metadata.sequence.stream).to eq(1)
    end

    it 'can be acknowledged' do
      expect { message.ack }.not_to raise_error

      # Message should be removed from queue
      messages = subscription.fetch(10, timeout: 1)
      expect(messages).to be_empty
    end

    it 'can be negatively acknowledged' do
      message.nak

      # Message should still be in queue
      messages = subscription.fetch(10, timeout: 1)
      expect(messages.size).to eq(1)
    end

    it 'can be terminated' do
      message.term

      # Message should be removed from queue
      messages = subscription.fetch(10, timeout: 1)
      expect(messages).to be_empty
    end

    it 'tracks delivery count' do
      msg1 = subscription.fetch(1, timeout: 1).first
      expect(msg1.metadata.num_delivered).to eq(1)

      msg1.nak

      msg2 = subscription.fetch(1, timeout: 1).first
      expect(msg2.metadata.num_delivered).to eq(2)
    end
  end

  describe 'InMemoryStorage' do
    let(:storage) { described_class.storage }

    before { storage.reset! }

    it 'stores and retrieves messages' do
      storage.publish('test.subject', 'data', { 'nats-msg-id' => 'id-1' })

      storage.create_subscription('test.subject', 'consumer', stream: 'test-stream')
      messages = storage.fetch_messages('test.subject', 'consumer', 10, 1)

      expect(messages.size).to eq(1)
      expect(messages.first.data).to eq('data')
    end

    it 'respects max_deliver setting' do
      storage.publish('test.subject', 'data', { 'nats-msg-id' => 'id-1' })
      storage.create_subscription('test.subject', 'consumer', stream: 'test-stream', max_deliver: 2)

      # First delivery
      msgs1 = storage.fetch_messages('test.subject', 'consumer', 10, 1)
      expect(msgs1.size).to eq(1)
      msgs1.first.nak

      # Second delivery
      msgs2 = storage.fetch_messages('test.subject', 'consumer', 10, 1)
      expect(msgs2.size).to eq(1)
      msgs2.first.nak

      # Third attempt - should be empty (max_deliver = 2)
      msgs3 = storage.fetch_messages('test.subject', 'consumer', 10, 1)
      expect(msgs3).to be_empty
    end

    it 'manages streams' do
      storage.add_stream(name: 'stream-1', subjects: ['test.>'])
      stream = storage.find_stream('stream-1')

      expect(stream).not_to be_nil
      expect(stream.name).to eq('stream-1')
    end

    it 'manages consumers' do
      storage.create_subscription('test.subject', 'consumer-1', stream: 'test-stream')
      consumer = storage.find_consumer('test-stream', 'consumer-1')

      expect(consumer).not_to be_nil
      expect(consumer.name).to eq('consumer-1')
    end
  end

  describe 'integration with test helpers' do
    include JetstreamBridge::TestHelpers

    before do
      JetstreamBridge.reset!
      JetstreamBridge::TestHelpers.enable_test_mode!
    end

    after do
      JetstreamBridge::TestHelpers.reset_test_mode!
    end

    it 'provides mock connection' do
      expect(JetstreamBridge::TestHelpers.mock_connection).to be_a(
        JetstreamBridge::TestHelpers::MockNats::MockConnection
      )
    end

    it 'provides mock storage' do
      expect(JetstreamBridge::TestHelpers.mock_storage).to be_a(
        JetstreamBridge::TestHelpers::MockNats::InMemoryStorage
      )
    end
  end
end
