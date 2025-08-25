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
    it 'ensures and subscribes the consumer' do
      described_class.new(durable_name: 'durable') { |*| }
      expect(sub_mgr).to have_received(:ensure_consumer!)
      expect(sub_mgr).to have_received(:subscribe!)
    end
  end

  describe '#process_batch' do
    subject(:consumer) { described_class.new(durable_name: 'durable') { |*| } }

    it 'processes fetched messages' do
      msg1 = double('msg1')
      msg2 = double('msg2')
      allow(subscription).to receive(:fetch).and_return([msg1, msg2])

      expect(processor).to receive(:handle_message).with(msg1).ordered
      expect(processor).to receive(:handle_message).with(msg2).ordered

      expect(consumer.send(:process_batch)).to eq(2)
    end

    it 'recovers subscription on recoverable JetStream error' do
      err = NATS::JetStream::Error.new('consumer not found')
      allow(subscription).to receive(:fetch).and_raise(err)

      expect(consumer.send(:process_batch)).to eq(0)
      expect(sub_mgr).to have_received(:ensure_consumer!).twice
      expect(sub_mgr).to have_received(:subscribe!).twice
    end
  end
end
