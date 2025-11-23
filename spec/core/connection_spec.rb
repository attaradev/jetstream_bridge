# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::Connection, :allow_real_connection do
  # Reset singleton between tests
  before do
    described_class.instance_variable_set(:@singleton__instance__, nil)
    # NOTE: @@connection_lock is now a class variable and persists across tests (intentional)

    # Ensure no mock NATS client is set from other tests
    if JetstreamBridge.instance_variable_defined?(:@mock_nats_client)
      JetstreamBridge.remove_instance_variable(:@mock_nats_client)
    end
  end

  let(:mock_nc) { double('NATS::Client', connected?: true) }
  let(:mock_jts) { double('JetStream', respond_to?: true) }
  let(:nats_urls) { 'nats://localhost:4222' }

  before do
    allow(JetstreamBridge).to receive(:config).and_return(
      double(
        nats_urls: nats_urls,
        logger: nil,
        connect_retry_attempts: 3,
        connect_retry_delay: 0.01 # Fast retries in tests
      )
    )
    allow(NATS::IO::Client).to receive(:new).and_return(mock_nc)
    allow(mock_nc).to receive(:on_reconnect)
    allow(mock_nc).to receive(:on_disconnect)
    allow(mock_nc).to receive(:on_error)
    allow(mock_nc).to receive(:connect).and_return(nil)
    allow(mock_nc).to receive(:jetstream).and_return(mock_jts)
    allow(mock_nc).to receive(:connected?).and_return(true)
    allow(mock_jts).to receive(:account_info).and_return(
      double(messages: 0, streams: 1, consumers: 2, memory: 1024, storage: 2048)
    )
    allow(mock_jts).to receive(:nc).and_return(mock_nc)
    allow(JetstreamBridge::Topology).to receive(:ensure!).and_return(true)
    allow(JetstreamBridge::Logging).to receive(:debug)
    allow(JetstreamBridge::Logging).to receive(:info)
    allow(JetstreamBridge::Logging).to receive(:warn)
    allow(JetstreamBridge::Logging).to receive(:error)
    allow(JetstreamBridge::Logging).to receive(:sanitize_url) { |url| url.gsub(/:([^@]+)@/, ':***@') }
  end

  describe '.connect!' do
    it 'returns a JetStream context' do
      result = described_class.connect!
      expect(result).to eq(mock_jts)
    end

    it 'is thread-safe' do
      results = []
      threads = Array.new(3) do
        Thread.new { results << described_class.connect! }
      end
      threads.each(&:join)

      expect(results).to all(eq(mock_jts))
      expect(NATS::IO::Client).to have_received(:new).once
    end

    it 'uses a class-level mutex for synchronization' do
      # Class-level mutex is defined at class load time, not lazily
      mutex = described_class.class_variable_get(:@@connection_lock)
      expect(mutex).to be_a(Mutex)

      # Verify it's the same mutex instance after connect
      described_class.connect!
      same_mutex = described_class.class_variable_get(:@@connection_lock)
      expect(same_mutex).to eq(mutex)
    end
  end

  describe '.nc' do
    it 'returns the NATS client' do
      described_class.connect!
      expect(described_class.nc).to eq(mock_nc)
    end
  end

  describe '.jetstream' do
    it 'returns the JetStream context' do
      described_class.connect!
      expect(described_class.jetstream).to eq(mock_jts)
    end
  end

  describe '#connect!' do
    let(:instance) { described_class.instance }

    context 'when already connected' do
      before do
        instance.instance_variable_set(:@nc, mock_nc)
        instance.instance_variable_set(:@jts, mock_jts)
      end

      it 'returns existing connection without reconnecting' do
        result = instance.connect!
        expect(result).to eq(mock_jts)
        expect(NATS::IO::Client).not_to have_received(:new)
      end
    end

    context 'when not connected' do
      it 'establishes new connection' do
        result = instance.connect!
        expect(result).to eq(mock_jts)
        expect(NATS::IO::Client).to have_received(:new)
      end

      it 'configures reconnect handler' do
        instance.connect!
        expect(mock_nc).to have_received(:on_reconnect)
      end

      it 'configures disconnect handler' do
        instance.connect!
        expect(mock_nc).to have_received(:on_disconnect)
      end

      it 'configures error handler' do
        instance.connect!
        expect(mock_nc).to have_received(:on_error)
      end

      it 'connects with default options' do
        instance.connect!
        expect(mock_nc).to have_received(:connect).with(
          hash_including(
            servers: ['nats://localhost:4222'],
            reconnect: true,
            reconnect_time_wait: 2,
            max_reconnect_attempts: 10,
            connect_timeout: 5
          )
        )
      end

      it 'ensures topology after connection' do
        instance.connect!
        expect(JetstreamBridge::Topology).to have_received(:ensure!).with(mock_jts).at_least(:once)
      end

      it 'sets connected_at timestamp' do
        freeze_time = Time.now.utc
        allow(Time).to receive_message_chain(:now, :utc).and_return(freeze_time)

        instance.connect!
        expect(instance.connected_at).to eq(freeze_time)
      end

      it 'logs connection success' do
        allow(JetstreamBridge::Logging).to receive(:info)
        instance.connect!
        expect(JetstreamBridge::Logging).to have_received(:info).with(
          /Connected to NATS/,
          tag: 'JetstreamBridge::Connection'
        )
      end
    end

    context 'with multiple NATS servers' do
      let(:nats_urls) { 'nats://server1:4222,nats://server2:4222, nats://server3:4222' }

      it 'connects to all servers' do
        instance.connect!
        expect(mock_nc).to have_received(:connect).with(
          hash_including(
            servers: ['nats://server1:4222', 'nats://server2:4222', 'nats://server3:4222']
          )
        )
      end
    end

    context 'with no NATS URLs' do
      let(:nats_urls) { '' }

      it 'raises error' do
        expect { instance.connect! }.to raise_error('No NATS URLs configured')
      end
    end

    context 'with invalid NATS URL format' do
      let(:nats_urls) { 'not-a-valid-url' }

      it 'raises ConnectionError with helpful message' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /Invalid NATS URL format/
        )
      end
    end

    context 'with invalid NATS URL scheme' do
      let(:nats_urls) { 'http://localhost:4222' }

      it 'raises ConnectionError' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /Invalid NATS URL scheme 'http'/
        )
      end
    end

    context 'with missing host in URL' do
      let(:nats_urls) { 'nats://:4222' }

      it 'raises ConnectionError' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /missing host/
        )
      end
    end

    context 'with invalid port number' do
      let(:nats_urls) { 'nats://localhost:99999' }

      it 'raises ConnectionError' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /port must be 1-65535/
        )
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_nc).to receive(:connected?).and_return(false)
      end

      it 'raises ConnectionError' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /Failed to establish connection/
        )
      end
    end

    context 'when JetStream is not enabled' do
      before do
        allow(mock_jts).to receive(:account_info).and_raise(NATS::IO::NoRespondersError)
      end

      it 'raises ConnectionError with helpful message' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /JetStream not enabled.*-js flag/
        )
      end
    end

    context 'when JetStream verification fails' do
      before do
        allow(mock_jts).to receive(:account_info).and_raise(StandardError, 'Connection timeout')
      end

      it 'raises ConnectionError' do
        expect { instance.connect! }.to raise_error(
          JetstreamBridge::ConnectionError,
          /JetStream verification failed.*Connection timeout/
        )
      end
    end

    context 'when JetStream context does not respond to nc' do
      before do
        allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      end

      it 'defines singleton method nc on JetStream context' do
        instance.connect!
        expect(mock_jts).to have_received(:respond_to?).with(:nc)
      end
    end
  end

  describe '#connected?' do
    let(:instance) { described_class.instance }

    context 'when fully connected' do
      before do
        instance.instance_variable_set(:@nc, mock_nc)
        instance.instance_variable_set(:@jts, mock_jts)
        allow(mock_nc).to receive(:connected?).and_return(true)
        allow(mock_jts).to receive(:account_info)
      end

      it 'returns true' do
        expect(instance.connected?).to be true
      end
    end

    context 'when NATS client is disconnected' do
      before do
        instance.instance_variable_set(:@nc, mock_nc)
        instance.instance_variable_set(:@jts, mock_jts)
        allow(mock_nc).to receive(:connected?).and_return(false)
      end

      it 'returns false' do
        expect(instance.connected?).to be false
      end
    end

    context 'when JetStream is not initialized' do
      before do
        instance.instance_variable_set(:@nc, mock_nc)
        instance.instance_variable_set(:@jts, nil)
        allow(mock_nc).to receive(:connected?).and_return(true)
      end

      it 'returns false' do
        expect(instance.connected?).to be false
      end
    end

    context 'when JetStream health check fails' do
      before do
        instance.instance_variable_set(:@nc, mock_nc)
        instance.instance_variable_set(:@jts, mock_jts)
        allow(mock_nc).to receive(:connected?).and_return(true)
        allow(mock_jts).to receive(:account_info).and_raise(StandardError, 'JetStream unavailable')
        allow(JetstreamBridge::Logging).to receive(:warn)
      end

      it 'returns false' do
        expect(instance.connected?).to be false
      end

      it 'logs warning' do
        instance.connected?
        expect(JetstreamBridge::Logging).to have_received(:warn).with(
          /JetStream health check failed/,
          tag: 'JetstreamBridge::Connection'
        )
      end
    end
  end

  describe '#connected_at' do
    let(:instance) { described_class.instance }

    it 'returns nil before connection' do
      expect(instance.connected_at).to be_nil
    end

    it 'returns timestamp after connection' do
      instance.connect!
      expect(instance.connected_at).to be_a(Time)
    end
  end

  describe 'reconnect handler' do
    let(:instance) { described_class.instance }
    let(:reconnect_callback) { proc {} }

    before do
      allow(mock_nc).to receive(:on_reconnect) do |&block|
        @reconnect_callback = block
      end
      allow(JetstreamBridge::Logging).to receive(:info)
    end

    it 'refreshes JetStream context on reconnect' do
      instance.connect!

      # Simulate reconnect
      @reconnect_callback.call

      expect(mock_nc).to have_received(:jetstream).at_least(:twice)
      expect(JetstreamBridge::Logging).to have_received(:info).with(
        'NATS reconnected, refreshing JetStream context',
        tag: 'JetstreamBridge::Connection'
      )
    end

    it 're-ensures topology after reconnect' do
      instance.connect!

      # Track calls after connect
      calls = []
      allow(JetstreamBridge::Topology).to receive(:ensure!) { |arg| calls << arg }

      # Simulate reconnect
      @reconnect_callback.call

      expect(calls).to eq([mock_jts])
    end

    context 'when refresh fails' do
      it 'logs error without crashing' do
        allow(JetstreamBridge::Logging).to receive(:error)

        # First call to jetstream succeeds (during connect!)
        # Subsequent calls fail (during reconnect)
        call_count = 0
        allow(mock_nc).to receive(:jetstream) do
          call_count += 1
          raise StandardError, 'Connection lost' unless call_count == 1

          mock_jts
        end

        instance.connect!

        expect { @reconnect_callback.call }.not_to raise_error
        expect(JetstreamBridge::Logging).to have_received(:error).with(
          /Failed to refresh JetStream context/,
          tag: 'JetstreamBridge::Connection'
        )
      end
    end
  end

  describe 'disconnect handler' do
    let(:instance) { described_class.instance }

    before do
      allow(mock_nc).to receive(:on_disconnect) do |&block|
        @disconnect_callback = block
      end
      allow(JetstreamBridge::Logging).to receive(:warn)
    end

    it 'logs disconnect reason' do
      instance.connect!

      # Simulate disconnect
      @disconnect_callback.call('Server shutdown')

      expect(JetstreamBridge::Logging).to have_received(:warn).with(
        'NATS disconnected: Server shutdown',
        tag: 'JetstreamBridge::Connection'
      )
    end
  end

  describe 'error handler' do
    let(:instance) { described_class.instance }

    before do
      allow(mock_nc).to receive(:on_error) do |&block|
        @error_callback = block
      end
      allow(JetstreamBridge::Logging).to receive(:error)
    end

    it 'logs errors' do
      instance.connect!

      # Simulate error
      error = StandardError.new('Connection timeout')
      @error_callback.call(error)

      expect(JetstreamBridge::Logging).to have_received(:error).with(
        /NATS error.*Connection timeout/,
        tag: 'JetstreamBridge::Connection'
      )
    end
  end

  describe 'URL sanitization' do
    let(:instance) { described_class.instance }

    context 'with credentials in URL' do
      let(:nats_urls) { 'nats://user:password@localhost:4222' }

      before do
        allow(JetstreamBridge::Logging).to receive(:sanitize_url).and_return('nats://user:***@localhost:4222')
        allow(JetstreamBridge::Logging).to receive(:info)
      end

      it 'sanitizes credentials in logs' do
        instance.connect!
        expect(JetstreamBridge::Logging).to have_received(:sanitize_url).at_least(:once)
      end
    end
  end
end
