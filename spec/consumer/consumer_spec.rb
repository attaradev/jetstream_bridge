# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge::Consumer do
  let(:jts) { double('jetstream') }
  let(:subscription) { double('subscription') }
  let(:sub_mgr) { instance_double(JetstreamBridge::SubscriptionManager) }
  let(:processor) { instance_double(JetstreamBridge::MessageProcessor) }

  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure { |c| c.destination_app = 'dest' }
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
    allow(JetstreamBridge::SubscriptionManager).to receive(:new).and_return(sub_mgr)
    allow(JetstreamBridge::MessageProcessor).to receive(:new).and_return(processor)
    allow(sub_mgr).to receive(:ensure_consumer!)
    allow(sub_mgr).to receive(:subscribe!).and_return(subscription)
    allow(processor).to receive(:handle_message)
  end

  after { JetstreamBridge.reset! }

  describe 'initialization' do
    it 'ensures and subscribes the consumer with block' do
      described_class.new { |*| nil }
      expect(JetstreamBridge::SubscriptionManager)
        .to have_received(:new)
        .with(jts, JetstreamBridge.config.durable_name, JetstreamBridge.config)
      expect(sub_mgr).to have_received(:ensure_consumer!)
      expect(sub_mgr).to have_received(:subscribe!)
    end

    it 'accepts handler as first argument' do
      handler = -> {}
      consumer = described_class.new(handler)
      expect(consumer).to be_a(described_class)
    end

    it 'raises error when neither handler nor block provided' do
      expect do
        described_class.new
      end.to raise_error(ArgumentError, /handler or block required/)
    end

    it 'accepts custom durable_name and batch_size' do
      consumer = described_class.new(durable_name: 'custom-durable', batch_size: 50) { |*| nil }
      expect(consumer.durable).to eq('custom-durable')
      expect(consumer.batch_size).to eq(50)
    end
  end

  describe '#process_batch' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'processes fetched messages' do
      msg1 = double('msg1')
      msg2 = double('msg2')
      allow(subscription).to receive(:fetch).and_return([msg1, msg2])

      expect(processor).to receive(:handle_message).with(msg1).ordered
      expect(processor).to receive(:handle_message).with(msg2).ordered

      expect(consumer.send(:process_batch)).to eq(2)
    end

    it 'returns 0 when no messages are fetched' do
      allow(subscription).to receive(:fetch).and_return([])
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'returns 0 when fetch returns nil' do
      allow(subscription).to receive(:fetch).and_return(nil)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'handles NATS::Timeout gracefully' do
      allow(subscription).to receive(:fetch).and_raise(NATS::Timeout)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'handles NATS::IO::Timeout gracefully' do
      allow(subscription).to receive(:fetch).and_raise(NATS::IO::Timeout)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'recovers subscription on recoverable JetStream error' do
      err = NATS::JetStream::Error.new('consumer not found')
      allow(subscription).to receive(:fetch).and_raise(err)

      expect(consumer.send(:process_batch)).to eq(0)
      expect(sub_mgr).to have_received(:ensure_consumer!).twice
      expect(sub_mgr).to have_received(:subscribe!).twice
    end

    it 'handles non-recoverable JetStream errors' do
      err = NATS::JetStream::Error.new('some other error')
      allow(subscription).to receive(:fetch).and_raise(err)

      expect(consumer.send(:process_batch)).to eq(0)
      # Should not attempt recovery for non-recoverable errors
      expect(sub_mgr).to have_received(:ensure_consumer!).once
    end

    it 'handles StandardError in process_batch' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'unexpected error')
      expect(consumer.send(:process_batch)).to eq(0)
    end
  end

  describe '#process_one' do
    subject(:consumer) { described_class.new { |*| nil } }

    let(:msg) { double('msg') }

    it 'processes message through handler' do
      expect(processor).to receive(:handle_message).with(msg)
      expect(consumer.send(:process_one, msg)).to eq(1)
    end

    it 'handles errors in message processing' do
      allow(processor).to receive(:handle_message).and_raise(StandardError, 'boom')
      expect(consumer.send(:process_one, msg)).to eq(0)
    end
  end

  describe '#stop!' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'sets shutdown_requested and running flags' do
      consumer.stop!
      expect(consumer.instance_variable_get(:@shutdown_requested)).to be true
      expect(consumer.instance_variable_get(:@running)).to be false
    end
  end

  describe 'with inbox enabled' do
    before do
      JetstreamBridge.configure { |c| c.use_inbox = true }
    end

    it 'initializes inbox processor' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      expect(consumer.instance_variable_get(:@inbox_proc)).to eq(inbox_proc)
    end

    it 'processes messages through inbox processor' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      msg = double('msg')

      expect(inbox_proc).to receive(:process).with(msg).and_return(true)
      expect(consumer.send(:process_one, msg)).to eq(1)
    end

    it 'returns 0 when inbox processor returns false' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      msg = double('msg')

      expect(inbox_proc).to receive(:process).with(msg).and_return(false)
      expect(consumer.send(:process_one, msg)).to eq(0)
    end
  end

  describe '#recoverable_consumer_error?' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'recognizes consumer not found error' do
      error = NATS::JetStream::Error.new('consumer not found')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes consumer deleted error' do
      error = NATS::JetStream::Error.new('consumer was deleted')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes no responders error' do
      error = NATS::JetStream::Error.new('no responders available')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes stream not found error' do
      error = NATS::JetStream::Error.new('stream not found')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes 404 error code' do
      error = NATS::JetStream::Error.new('err_code=404')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'does not consider other errors as recoverable' do
      error = NATS::JetStream::Error.new('some other error')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_falsey
    end
  end

  describe '#idle_sleep' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'increases backoff when no messages processed' do
      initial_backoff = consumer.instance_variable_get(:@idle_backoff)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 0)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to be > initial_backoff
    end

    it 'resets backoff when messages are processed' do
      consumer.instance_variable_set(:@idle_backoff, 0.5)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 5)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to eq(described_class::IDLE_SLEEP_SECS)
    end

    it 'caps backoff at MAX_IDLE_BACKOFF_SECS' do
      consumer.instance_variable_set(:@idle_backoff, 2.0)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 0)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to be <= described_class::MAX_IDLE_BACKOFF_SECS
    end
  end

  describe '#drain_inflight_messages' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'processes pending messages during drain' do
      msg = double('msg')
      allow(subscription).to receive(:fetch).and_return([msg], [])
      allow(processor).to receive(:handle_message)

      consumer.send(:drain_inflight_messages)
      expect(processor).to have_received(:handle_message).with(msg)
    end

    it 'stops on timeout during drain' do
      allow(subscription).to receive(:fetch).and_raise(NATS::Timeout)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'stops on NATS::IO::Timeout during drain' do
      allow(subscription).to receive(:fetch).and_raise(NATS::IO::Timeout)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'handles errors during drain gracefully' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'drain error')
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'returns early if @psub is nil' do
      consumer.instance_variable_set(:@psub, nil)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end
  end

  describe 'initialization with missing destination_app' do
    before do
      JetstreamBridge.configure { |c| c.destination_app = nil }
    end

    it 'raises ArgumentError' do
      expect do
        described_class.new { |*| nil }
      end.to raise_error(ArgumentError, /destination_app must be configured/)
    end
  end
end
