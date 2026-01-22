# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::ConnectionManager do
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.app_name = 'test_app'
      c.destination_app = 'worker'
      c.stream_name = 'TEST'
      c.validate!
    end
  end

  let(:connection_manager) { described_class.new(config) }

  describe '#initialize' do
    it 'initializes with config' do
      expect(connection_manager.config).to eq(config)
    end

    it 'starts in disconnected state' do
      expect(connection_manager.state).to eq(described_class::State::DISCONNECTED)
    end
  end

  describe '#connect!' do
    let(:mock_nc) { instance_double(NATS::IO::Client) }
    let(:mock_jts) { double('jetstream') }

    before do
      allow(NATS::IO::Client).to receive(:new).and_return(mock_nc)
      allow(mock_nc).to receive(:connect)
      allow(mock_nc).to receive(:connected?).and_return(true)
      allow(mock_nc).to receive(:jetstream).and_return(mock_jts)
      allow(mock_nc).to receive(:on_reconnect)
      allow(mock_nc).to receive(:on_disconnect)
      allow(mock_nc).to receive(:on_error)

      allow(mock_jts).to receive(:account_info).and_return(
        double(streams: 1, consumers: 1, memory: 1024, storage: 2048)
      )
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:define_singleton_method)

      allow(JetstreamBridge::Topology).to receive(:ensure!)
    end

    it 'establishes connection' do
      connection_manager.connect!

      expect(connection_manager.state).to eq(described_class::State::CONNECTED)
      expect(connection_manager.connected?).to be true
    end

    it 'is idempotent' do
      connection_manager.connect!
      connection_manager.connect!

      expect(NATS::IO::Client).to have_received(:new).once
    end

    it 'validates NATS URLs' do
      config.nats_urls = 'invalid'

      expect do
        connection_manager.connect!
      end.to raise_error(JetstreamBridge::ConnectionError, /Invalid NATS URL/)
    end

    it 'verifies JetStream availability' do
      config.disable_js_api = false
      allow(mock_jts).to receive(:account_info).and_raise(NATS::IO::NoRespondersError)

      expect do
        connection_manager.connect!
      end.to raise_error(JetstreamBridge::ConnectionError, /JetStream not enabled/)
    end
  end

  describe '#disconnect!' do
    let(:mock_nc) { instance_double(NATS::IO::Client) }
    let(:mock_jts) { double('jetstream') }

    before do
      allow(NATS::IO::Client).to receive(:new).and_return(mock_nc)
      allow(mock_nc).to receive(:connect)
      allow(mock_nc).to receive(:connected?).and_return(true)
      allow(mock_nc).to receive(:jetstream).and_return(mock_jts)
      allow(mock_nc).to receive(:on_reconnect)
      allow(mock_nc).to receive(:on_disconnect)
      allow(mock_nc).to receive(:on_error)
      allow(mock_nc).to receive(:close)

      allow(mock_jts).to receive(:account_info).and_return(
        double(streams: 1, consumers: 1, memory: 1024, storage: 2048)
      )
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:define_singleton_method)

      allow(JetstreamBridge::Topology).to receive(:ensure!)

      connection_manager.connect!
    end

    it 'closes connection' do
      connection_manager.disconnect!

      expect(mock_nc).to have_received(:close)
      expect(connection_manager.state).to eq(described_class::State::DISCONNECTED)
    end
  end

  describe '#connected?' do
    it 'returns false when not connected' do
      expect(connection_manager.connected?).to be false
    end

    it 'caches health check results' do
      config.disable_js_api = false
      mock_nc = instance_double(NATS::IO::Client)
      mock_jts = double('jetstream')

      allow(NATS::IO::Client).to receive(:new).and_return(mock_nc)
      allow(mock_nc).to receive(:connect)
      allow(mock_nc).to receive(:connected?).and_return(true)
      allow(mock_nc).to receive(:jetstream).and_return(mock_jts)
      allow(mock_nc).to receive(:on_reconnect)
      allow(mock_nc).to receive(:on_disconnect)
      allow(mock_nc).to receive(:on_error)

      allow(mock_jts).to receive(:account_info).and_return(
        double(streams: 1, consumers: 1, memory: 1024, storage: 2048)
      )
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:define_singleton_method)

      allow(JetstreamBridge::Topology).to receive(:ensure!)

      connection_manager.connect!

      # First call should check JetStream
      connection_manager.connected?
      expect(mock_jts).to have_received(:account_info).twice # once during connect, once during connected?

      # Second call within 30s should use cache
      connection_manager.connected?
      expect(mock_jts).to have_received(:account_info).twice # still twice, cached
    end
  end
end
