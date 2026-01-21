# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::Facade do
  let(:facade) { described_class.new }

  describe '#configure' do
    it 'yields configuration block' do
      facade.configure do |config|
        config.app_name = 'test_app'
        config.destination_app = 'worker'
        config.stream_name = 'TEST'
      end

      expect(facade.config.app_name).to eq('test_app')
      expect(facade.config.destination_app).to eq('worker')
      expect(facade.config.stream_name).to eq('TEST')
    end

    it 'returns config' do
      result = facade.configure { |c| c.app_name = 'test' }
      expect(result).to be_a(JetstreamBridge::Config)
    end
  end

  describe '#connect!' do
    before do
      facade.configure do |config|
        config.nats_urls = 'nats://localhost:4222'
        config.app_name = 'test_app'
        config.destination_app = 'worker'
        config.stream_name = 'TEST'
      end
    end

    it 'validates configuration before connecting' do
      facade.config.stream_name = nil

      expect {
        facade.connect!
      }.to raise_error(JetstreamBridge::ConfigurationError, /stream_name is required/)
    end

    it 'creates connection manager and connects' do
      connection_manager = instance_double(JetstreamBridge::ConnectionManager)
      allow(JetstreamBridge::ConnectionManager).to receive(:new).and_return(connection_manager)
      allow(connection_manager).to receive(:connect!)

      facade.connect!

      expect(connection_manager).to have_received(:connect!)
    end
  end

  describe '#disconnect!' do
    it 'disconnects if connection manager exists' do
      connection_manager = instance_double(JetstreamBridge::ConnectionManager)
      allow(JetstreamBridge::ConnectionManager).to receive(:new).and_return(connection_manager)
      allow(connection_manager).to receive(:connect!)
      allow(connection_manager).to receive(:disconnect!)

      facade.configure do |config|
        config.nats_urls = 'nats://localhost:4222'
        config.app_name = 'test'
        config.destination_app = 'worker'
        config.stream_name = 'TEST'
      end

      facade.connect!
      facade.disconnect!

      expect(connection_manager).to have_received(:disconnect!)
    end

    it 'does nothing if not connected' do
      expect { facade.disconnect! }.not_to raise_error
    end
  end

  describe '#connected?' do
    it 'returns false if connection manager does not exist' do
      expect(facade.connected?).to be false
    end

    it 'delegates to connection manager if it exists' do
      connection_manager = instance_double(JetstreamBridge::ConnectionManager)
      allow(JetstreamBridge::ConnectionManager).to receive(:new).and_return(connection_manager)
      allow(connection_manager).to receive(:connect!)
      allow(connection_manager).to receive(:connected?).and_return(true)

      facade.configure do |config|
        config.nats_urls = 'nats://localhost:4222'
        config.app_name = 'test'
        config.destination_app = 'worker'
        config.stream_name = 'TEST'
      end

      facade.connect!

      expect(facade.connected?).to be true
    end
  end

  describe '#health_check' do
    it 'returns unhealthy status if not connected' do
      health = facade.health_check

      expect(health[:healthy]).to be false
      expect(health[:connection][:connected]).to be false
    end

    it 'enforces rate limit on uncached checks' do
      facade.health(skip_cache: true)

      result = facade.health(skip_cache: true)

      expect(result[:healthy]).to be false
      expect(result[:error]).to match(/rate limit/)
    end
  end
end
