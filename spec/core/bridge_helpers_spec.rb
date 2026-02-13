# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge'

RSpec.describe JetstreamBridge::Core::BridgeHelpers do
  # Use the main module as a harness since it includes BridgeHelpers privately.
  before do
    JetstreamBridge.instance_variable_set(:@last_uncached_health_check, nil)
    JetstreamBridge.instance_variable_set(:@health_check_mutex, nil)
    @original_connection_initialized = JetstreamBridge.instance_variable_get(:@connection_initialized)
  end

  after do
    JetstreamBridge.instance_variable_set(:@last_uncached_health_check, nil)
    JetstreamBridge.instance_variable_set(:@health_check_mutex, nil)
    JetstreamBridge.instance_variable_set(:@connection_initialized, @original_connection_initialized)
  end

  describe '#connect_if_needed!' do
    it 'starts up when connection has not been initialized' do
      JetstreamBridge.instance_variable_set(:@connection_initialized, false)

      expect(JetstreamBridge).to receive(:startup!)

      JetstreamBridge.send(:connect_if_needed!)
    end

    it 'does not reconnect when already initialized and healthy' do
      JetstreamBridge.instance_variable_set(:@connection_initialized, true)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(double('jetstream'))

      expect(JetstreamBridge).not_to receive(:reconnect!)

      JetstreamBridge.send(:connect_if_needed!)
    end

    it 'reconnects when initialized but connection health is false' do
      JetstreamBridge.instance_variable_set(:@connection_initialized, true)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_raise(
        JetstreamBridge::ConnectionNotEstablishedError,
        'JetStream context unavailable (refresh pending or failed)'
      )
      allow(JetstreamBridge::Logging).to receive(:warn)

      expect(JetstreamBridge).to receive(:reconnect!)

      JetstreamBridge.send(:connect_if_needed!)

      expect(JetstreamBridge::Logging).to have_received(:warn).with(
        'JetStream context unavailable on initialized connection. Attempting reconnect before operation.',
        tag: 'JetstreamBridge'
      )
    end
  end

  describe '#enforce_health_check_rate_limit!' do
    it 'allows the first uncached request and records timestamp' do
      JetstreamBridge.send(:enforce_health_check_rate_limit!)

      last_check = JetstreamBridge.instance_variable_get(:@last_uncached_health_check)
      expect(last_check).to be_within(0.5).of(Time.now)
    end

    it 'raises when called again within 5 seconds' do
      JetstreamBridge.send(:enforce_health_check_rate_limit!)

      expect do
        JetstreamBridge.send(:enforce_health_check_rate_limit!)
      end.to raise_error(JetstreamBridge::HealthCheckFailedError, /rate limit exceeded/)
    end
  end

  describe '#normalize_ms' do
    it 'converts seconds to milliseconds when value is less than 1' do
      expect(JetstreamBridge.send(:normalize_ms, 0.25)).to eq(250.0)
    end

    it 'returns milliseconds unchanged when value is already >= 1' do
      expect(JetstreamBridge.send(:normalize_ms, 42)).to eq(42)
    end

    it 'returns nil for non-numeric values' do
      expect(JetstreamBridge.send(:normalize_ms, nil)).to be_nil
      expect(JetstreamBridge.send(:normalize_ms, Object.new)).to be_nil
    end
  end
end
