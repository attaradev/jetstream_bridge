# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge do
  let(:jts) { double('jetstream', publish: double(duplicate?: false, error: nil)) }

  before do
    described_class.reset!
    described_class.configure do |c|
      c.destination_app = 'dest'
      c.app_name = 'source'
      c.env = 'test'
    end
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
  end

  after { described_class.reset! }

  describe '.ensure_topology!' do
    it 'connects and returns the jetstream context' do
      expect(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      expect(described_class.ensure_topology!).to eq(jts)
    end
  end

  describe '.publish' do
    it 'publishes with structured parameters' do
      expect(jts).to receive(:publish) do |subject, data, header:|
        expect(subject).to eq('test.source.sync.dest')
        expect(header).to be_a(Hash)
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['event_type']).to eq('created')
        expect(envelope['resource_type']).to eq('user')
        double(duplicate?: false, error: nil)
      end

      result = described_class.publish(
        resource_type: 'user',
        event_type: 'created',
        payload: { id: 1, name: 'Ada' }
      )
      expect(result).to be(true)
    end

    it 'publishes with simplified hash (infers resource_type)' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        expect(header).to be_a(Hash)
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['event_type']).to eq('user.created')
        expect(envelope['resource_type']).to eq('user')
        double(duplicate?: false, error: nil)
      end

      result = described_class.publish(
        event_type: 'user.created',
        payload: { id: 1, name: 'Ada' }
      )
      expect(result).to be(true)
    end

    it 'publishes with complete envelope hash' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        expect(header).to be_a(Hash)
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['event_id']).to eq('custom-123')
        double(duplicate?: false, error: nil)
      end

      result = described_class.publish(
        event_type: 'user.created',
        payload: { id: 1 },
        event_id: 'custom-123'
      )
      expect(result).to be(true)
    end
  end

  describe '.subscribe' do
    let(:sub_mgr) { instance_double(JetstreamBridge::SubscriptionManager) }
    let(:subscription) { double('subscription') }

    before do
      allow(JetstreamBridge::SubscriptionManager).to receive(:new).and_return(sub_mgr)
      allow(sub_mgr).to receive(:ensure_consumer!)
      allow(sub_mgr).to receive(:subscribe!).and_return(subscription)
      allow(JetstreamBridge::MessageProcessor).to receive(:new)
    end

    it 'returns consumer instance when run: false' do
      consumer = described_class.subscribe { nil }
      expect(consumer).to be_a(JetstreamBridge::Consumer)
    end

    it 'returns thread when run: true' do
      allow_any_instance_of(JetstreamBridge::Consumer).to receive(:run!)

      result = described_class.subscribe(run: true) { nil }
      expect(result).to be_a(Thread)
      result.kill # Clean up thread
    end

    it 'accepts handler as first argument' do
      handler = ->(_event, _context) {}
      consumer = described_class.subscribe(handler)
      expect(consumer).to be_a(JetstreamBridge::Consumer)
    end

    it 'accepts custom durable_name and batch_size' do
      consumer = described_class.subscribe(durable_name: 'custom', batch_size: 50) { nil }
      expect(consumer.durable).to eq('custom')
      expect(consumer.batch_size).to eq(50)
    end

    it 'raises error when neither handler nor block provided' do
      expect do
        described_class.subscribe
      end.to raise_error(ArgumentError, /Handler or block required/)
    end
  end

  describe '.health_check' do
    let(:conn_instance) do
      double('Connection',
             connected?: true,
             connected_at: Time.utc(2024, 1, 1, 12, 0, 0))
    end

    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.*']),
             state: double(messages: 42))
    end

    before do
      allow(JetstreamBridge::Connection).to receive(:instance).and_return(conn_instance)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(jts).to receive(:stream_info).and_return(stream_info_data)
    end

    it 'returns health status hash' do
      result = described_class.health_check
      expect(result).to be_a(Hash)
      expect(result).to have_key(:healthy)
      expect(result).to have_key(:nats_connected)
      expect(result).to have_key(:stream)
      expect(result).to have_key(:config)
      expect(result).to have_key(:version)
    end

    it 'indicates healthy when connected and stream exists' do
      result = described_class.health_check
      expect(result[:healthy]).to be true
      expect(result[:nats_connected]).to be true
    end

    it 'includes connected_at timestamp' do
      result = described_class.health_check
      expect(result[:connected_at]).to eq('2024-01-01T12:00:00Z')
    end

    it 'includes stream information' do
      result = described_class.health_check
      expect(result[:stream][:exists]).to be true
      expect(result[:stream][:subjects]).to eq(['test.*'])
      expect(result[:stream][:messages]).to eq(42)
    end

    it 'includes config information' do
      result = described_class.health_check
      expect(result[:config][:env]).to eq('test')
      expect(result[:config][:app_name]).to eq('source')
      expect(result[:config][:destination_app]).to eq('dest')
    end

    it 'includes version' do
      result = described_class.health_check
      expect(result[:version]).to eq(JetstreamBridge::VERSION)
    end

    context 'when not connected' do
      before do
        allow(conn_instance).to receive(:connected?).and_return(false)
      end

      it 'indicates unhealthy' do
        result = described_class.health_check
        expect(result[:healthy]).to be false
        expect(result[:nats_connected]).to be false
      end

      it 'does not fetch stream info' do
        expect(jts).not_to receive(:stream_info)
        described_class.health_check
      end
    end

    context 'when stream does not exist' do
      before do
        allow(jts).to receive(:stream_info).and_raise(StandardError, 'Stream not found')
      end

      it 'indicates stream does not exist' do
        result = described_class.health_check
        expect(result[:stream][:exists]).to be false
        expect(result[:stream][:error]).to include('Stream not found')
      end

      it 'still reports as unhealthy' do
        result = described_class.health_check
        expect(result[:healthy]).to be false
      end
    end

    context 'when health check raises error' do
      before do
        allow(JetstreamBridge::Connection).to receive(:instance).and_raise(StandardError, 'Connection error')
      end

      it 'returns error hash' do
        result = described_class.health_check
        expect(result[:healthy]).to be false
        expect(result[:error]).to eq('StandardError: Connection error')
      end
    end
  end

  describe '.connected?' do
    let(:conn_instance) { double('Connection') }

    before do
      allow(JetstreamBridge::Connection).to receive(:instance).and_return(conn_instance)
    end

    it 'returns true when connected' do
      allow(conn_instance).to receive(:connected?).and_return(true)
      expect(described_class.connected?).to be true
    end

    it 'returns false when not connected' do
      allow(conn_instance).to receive(:connected?).and_return(false)
      expect(described_class.connected?).to be false
    end

    it 'returns false on error' do
      allow(conn_instance).to receive(:connected?).and_raise(StandardError)
      expect(described_class.connected?).to be false
    end
  end

  describe '.stream_info' do
    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.subject']),
             state: double(messages: 10))
    end

    before do
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(jts).to receive(:stream_info).and_return(stream_info_data)
    end

    it 'returns stream information' do
      result = described_class.stream_info
      expect(result[:exists]).to be true
      expect(result[:name]).to eq('test-jetstream-bridge-stream')
      expect(result[:subjects]).to eq(['test.subject'])
      expect(result[:messages]).to eq(10)
    end

    context 'when stream fetch fails' do
      before do
        allow(jts).to receive(:stream_info).and_raise(StandardError, 'Fetch failed')
      end

      it 'returns error information' do
        result = described_class.stream_info
        expect(result[:exists]).to be false
        expect(result[:error]).to include('Fetch failed')
      end
    end
  end

  describe '.use_outbox?' do
    it 'returns config value' do
      described_class.config.use_outbox = true
      expect(described_class.use_outbox?).to be true
    end
  end

  describe '.use_inbox?' do
    it 'returns config value' do
      described_class.config.use_inbox = true
      expect(described_class.use_inbox?).to be true
    end
  end

  describe '.use_dlq?' do
    it 'returns config value' do
      described_class.config.use_dlq = true
      expect(described_class.use_dlq?).to be true
    end
  end

  describe '.configure' do
    it 'accepts hash overrides' do
      described_class.configure(env: 'production', app_name: 'my_app')
      expect(described_class.config.env).to eq('production')
      expect(described_class.config.app_name).to eq('my_app')
    end

    it 'accepts block configuration' do
      described_class.configure do |c|
        c.env = 'staging'
        c.app_name = 'test'
      end
      expect(described_class.config.env).to eq('staging')
      expect(described_class.config.app_name).to eq('test')
    end

    it 'accepts both hash and block' do
      described_class.configure(env: 'dev') do |c|
        c.app_name = 'combined'
      end
      expect(described_class.config.env).to eq('dev')
      expect(described_class.config.app_name).to eq('combined')
    end

    it 'raises error for unknown option' do
      expect do
        described_class.configure(unknown_option: 'value')
      end.to raise_error(ArgumentError, /Unknown configuration option/)
    end

    it 'handles nil overrides' do
      expect do
        described_class.configure(nil) { |c| c.env = 'test' }
      end.not_to raise_error
    end

    it 'handles empty hash overrides' do
      expect do
        described_class.configure({}) { |c| c.env = 'test' }
      end.not_to raise_error
    end
  end

  describe '.reset!' do
    it 'clears the configuration' do
      described_class.configure { |c| c.env = 'custom' }
      described_class.reset!
      expect(described_class.config.env).to eq('development')
    end
  end
end
