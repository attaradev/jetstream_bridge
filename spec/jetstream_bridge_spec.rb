# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge do
  let(:mock_stream_info) do
    double('stream_info',
           config: double('config',
                          subjects: ['source.sync.dest', 'dest.sync.source'],
                          retention: 'workqueue',
                          storage: 'file'))
  end
  let(:jts) do
    double('jetstream',
           publish: double(duplicate?: false, error: nil),
           stream_info: mock_stream_info)
  end

  before do
    described_class.reset!
    allow(JetstreamBridge::Topology).to receive(:provision!)

    # Ensure no mock NATS client is set from other tests
    if JetstreamBridge.instance_variable_defined?(:@mock_nats_client)
      JetstreamBridge.remove_instance_variable(:@mock_nats_client)
    end

    # Configure without connecting (new behavior)
    described_class.configure do |c|
      c.destination_app = 'dest'
      c.app_name = 'source'
      c.stream_name = 'jetstream-bridge-stream'
    end
    # Mock connection for operations that need it
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
    allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
    # Mark as connected so auto-connect works
    described_class.instance_variable_set(:@connection_initialized, true)
  end

  after do
    described_class.reset!
    if JetstreamBridge.instance_variable_defined?(:@mock_nats_client)
      JetstreamBridge.remove_instance_variable(:@mock_nats_client)
    end
  end

  describe '.connect_and_provision!' do
    it 'connects, provisions topology, and returns the jetstream context' do
      expect(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
      expect(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      expect(JetstreamBridge::Topology).to receive(:provision!).with(jts)
      expect(described_class.connect_and_provision!).to eq(jts)
    end
  end

  describe '.publish' do
    it 'publishes with structured parameters' do
      expect(jts).to receive(:publish) do |subject, data, header:|
        expect(subject).to eq('source.sync.dest')
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
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
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
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
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
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
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
             connected_at: Time.utc(2024, 1, 1, 12, 0, 0),
             state: :connected,
             last_reconnect_error: nil,
             last_reconnect_error_at: nil)
    end

    let(:mock_nc) { double('NATS::Client', rtt: 0.005) }

    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.*']),
             state: double(messages: 42))
    end

    before do
      allow(JetstreamBridge::Connection).to receive(:instance).and_return(conn_instance)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(JetstreamBridge::Connection).to receive(:nc).and_return(mock_nc)
      allow(jts).to receive(:stream_info).and_return(stream_info_data)
      allow(JetstreamBridge::Logging).to receive(:warn)
    end

    it 'returns health status hash' do
      result = described_class.health_check
      expect(result).to be_a(Hash)
      expect(result).to have_key(:healthy)
      expect(result).to have_key(:connection)
      expect(result).to have_key(:stream)
      expect(result).to have_key(:performance)
      expect(result).to have_key(:config)
      expect(result).to have_key(:version)
    end

    it 'indicates healthy when connected and stream exists' do
      result = described_class.health_check
      expect(result[:healthy]).to be true
      expect(result[:connection][:connected]).to be true
      expect(result[:connection][:state]).to eq(:connected)
    end

    it 'includes connected_at timestamp' do
      result = described_class.health_check
      expect(result[:connection][:connected_at]).to eq('2024-01-01T12:00:00Z')
    end

    it 'includes stream information' do
      result = described_class.health_check
      expect(result[:stream][:exists]).to be true
      expect(result[:stream][:subjects]).to eq(['test.*'])
      expect(result[:stream][:messages]).to eq(42)
    end

    it 'includes config information' do
      result = described_class.health_check
      expect(result[:config][:stream_name]).to eq('jetstream-bridge-stream')
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
        allow(conn_instance).to receive(:state).and_return(:disconnected)
      end

      it 'indicates unhealthy' do
        result = described_class.health_check
        expect(result[:healthy]).to be false
        expect(result[:connection][:connected]).to be false
        expect(result[:connection][:state]).to eq(:disconnected)
      end

      it 'does not fetch stream info' do
        expect(jts).not_to receive(:stream_info)
        described_class.health_check
      end

      it 'does not measure RTT' do
        expect(mock_nc).not_to receive(:rtt)
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

    it 'includes performance metrics' do
      result = described_class.health_check
      expect(result[:performance]).to be_a(Hash)
      expect(result[:performance][:nats_rtt_ms]).to be_a(Numeric)
      expect(result[:performance][:health_check_duration_ms]).to be_a(Numeric)
      expect(result[:performance][:health_check_duration_ms]).to be > 0
    end

    it 'measures NATS RTT actively' do
      expect(mock_nc).to receive(:rtt)
      described_class.health_check
    end

    context 'when NATS client does not expose #rtt' do
      let(:mock_nc) { double('NATS::Client', flush: true) }

      it 'falls back to measuring via flush' do
        allow(mock_nc).to receive(:respond_to?).with(:rtt).and_return(false)
        expect(mock_nc).to receive(:flush).with(1)

        result = described_class.health_check
        expect(result[:performance][:nats_rtt_ms]).to be_a(Numeric)
      end
    end

    context 'when RTT measurement fails' do
      before do
        allow(mock_nc).to receive(:rtt).and_raise(StandardError, 'RTT failed')
      end

      it 'returns nil for RTT and logs warning' do
        result = described_class.health_check
        expect(result[:performance][:nats_rtt_ms]).to be_nil
        expect(JetstreamBridge::Logging).to have_received(:warn).with(
          /Failed to measure NATS RTT/,
          tag: 'JetstreamBridge'
        )
      end

      it 'still reports as healthy if connection works' do
        result = described_class.health_check
        expect(result[:healthy]).to be true
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
      expect(result[:name]).to eq('jetstream-bridge-stream')
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

    context 'when connection is not initialized' do
      before do
        described_class.reset!
        described_class.configure do |c|
          c.destination_app = 'dest'
          c.app_name = 'source'
          c.stream_name = 'jetstream-bridge-stream'
        end
      end

      it 'connects before fetching stream info' do
        connection_count = 0
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Logging).to receive(:info)

        result = described_class.stream_info
        expect(result[:exists]).to be true
        expect(connection_count).to eq(1)
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
    before do
      # Reset and clear mocks from top-level before block
      described_class.reset!
    end

    it 'accepts hash overrides' do
      described_class.configure(stream_name: 'custom-stream', app_name: 'my_app')
      expect(described_class.config.stream_name).to eq('custom-stream')
      expect(described_class.config.app_name).to eq('my_app')
    end

    it 'accepts block configuration' do
      described_class.configure do |c|
        c.stream_name = 'staging-stream'
        c.app_name = 'test'
      end
      expect(described_class.config.stream_name).to eq('staging-stream')
      expect(described_class.config.app_name).to eq('test')
    end

    it 'accepts both hash and block' do
      described_class.configure(stream_name: 'dev-stream') do |c|
        c.app_name = 'combined'
      end
      expect(described_class.config.stream_name).to eq('dev-stream')
      expect(described_class.config.app_name).to eq('combined')
    end

    it 'raises error for unknown option' do
      expect do
        described_class.configure(unknown_option: 'value')
      end.to raise_error(ArgumentError, /Unknown configuration option/)
    end

    it 'handles nil overrides' do
      expect do
        described_class.configure(nil) { |c| c.stream_name = 'test-stream' }
      end.not_to raise_error
    end

    it 'handles empty hash overrides' do
      expect do
        described_class.configure({}) { |c| c.stream_name = 'test-stream' }
      end.not_to raise_error
    end

    it 'does not establish connection automatically' do
      connection_count = 0
      allow(JetstreamBridge::Connection).to receive(:connect!) { connection_count += 1 }

      described_class.configure { |c| c.stream_name = 'test-stream' }

      expect(connection_count).to eq(0)
    end

    it 'returns config instance' do
      config = described_class.configure { |c| c.stream_name = 'test-stream' }

      expect(config).to be_a(JetstreamBridge::Config)
    end
  end

  describe '.reset!' do
    it 'clears the configuration' do
      described_class.configure { |c| c.stream_name = 'custom-stream' }
      described_class.reset!
      expect(described_class.config.stream_name).to eq('jetstream-bridge-stream')
    end

    it 'resets connection_initialized flag' do
      described_class.instance_variable_set(:@connection_initialized, true)
      described_class.reset!
      expect(described_class.instance_variable_get(:@connection_initialized)).to be false
    end
  end

  describe '.startup!' do
    before do
      described_class.reset!
      described_class.configure do |c|
        c.destination_app = 'dest'
        c.app_name = 'source'
        c.stream_name = 'jetstream-bridge-stream'
      end
    end

    it 'initializes the connection' do
      connection_count = 0
      allow(JetstreamBridge::Connection).to receive(:connect!) { connection_count += 1 }
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(JetstreamBridge::Logging).to receive(:info)

      described_class.startup!
      expect(connection_count).to eq(1)
    end
    it 'ensures topology after connecting' do
      allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(JetstreamBridge::Logging).to receive(:info)

      described_class.startup!
      expect(JetstreamBridge::Topology).to have_received(:provision!).with(jts)
    end

    it 'sets connection_initialized flag' do
      allow(JetstreamBridge::Connection).to receive(:connect!)
      allow(JetstreamBridge::Logging).to receive(:info)

      described_class.startup!
      expect(described_class.instance_variable_get(:@connection_initialized)).to be true
    end

    it 'is idempotent' do
      connection_count = 0
      allow(JetstreamBridge::Connection).to receive(:connect!) { connection_count += 1 }
      allow(JetstreamBridge::Logging).to receive(:info)

      described_class.startup!
      described_class.startup!
      expect(connection_count).to eq(1)
    end

    it 'logs successful startup' do
      allow(JetstreamBridge::Connection).to receive(:connect!)
      allow(JetstreamBridge::Logging).to receive(:info)

      described_class.startup!
      expect(JetstreamBridge::Logging).to have_received(:info).with(
        'JetStream Bridge started successfully',
        tag: 'JetstreamBridge'
      )
    end
  end

  describe 'auto-connect on first use' do
    before do
      # Reset without setting @connection_initialized so we can test auto-connect
      described_class.reset!

      described_class.configure do |c|
        c.destination_app = 'dest'
        c.app_name = 'source'
        c.stream_name = 'jetstream-bridge-stream'
      end
    end

    context 'when publishing' do
      it 'automatically connects on first publish' do
        connection_count = 0
        # Connection.jetstream is called from Publisher constructor after startup! completes
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Logging).to receive(:info)

        expect(jts).to receive(:publish).and_return(double(duplicate?: false, error: nil))

        described_class.publish(event_type: 'user.created', payload: { id: 1 })

        expect(connection_count).to eq(1)
      end

      it 'does not connect again on subsequent publishes' do
        connection_count = 0
        # jetstream returns jts for both Publisher constructor calls
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Logging).to receive(:info)
        allow(jts).to receive(:publish).and_return(double(duplicate?: false, error: nil))

        described_class.publish(event_type: 'user.created', payload: { id: 1 })
        described_class.publish(event_type: 'user.updated', payload: { id: 1 })

        expect(connection_count).to eq(1)
      end

      it 'skips connection if already started' do
        connection_count = 0
        # jetstream returns jts for Publisher constructor call
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Logging).to receive(:info)

        # Manually start first
        described_class.startup!
        expect(connection_count).to eq(1)

        # Publish should not connect again
        allow(jts).to receive(:publish).and_return(double(duplicate?: false, error: nil))
        described_class.publish(event_type: 'user.created', payload: { id: 1 })

        expect(connection_count).to eq(1)
      end
    end

    context 'when subscribing' do
      it 'automatically connects on first subscribe' do
        connection_count = 0
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Logging).to receive(:info)

        # Mock the consumer creation
        consumer = instance_double(JetstreamBridge::Consumer)
        allow(JetstreamBridge::Consumer).to receive(:new).and_return(consumer)

        described_class.subscribe { |event| puts event.type }

        expect(connection_count).to eq(1)
      end

      it 'skips connection if already started' do
        connection_count = 0
        allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
        allow(JetstreamBridge::Connection).to receive(:connect!) do
          connection_count += 1
          jts
        end
        allow(JetstreamBridge::Logging).to receive(:info)

        # Manually start first
        described_class.startup!
        expect(connection_count).to eq(1)

        # Subscribe should not connect again
        consumer = instance_double(JetstreamBridge::Consumer)
        allow(JetstreamBridge::Consumer).to receive(:new).and_return(consumer)
        described_class.subscribe { |event| puts event.type }

        expect(connection_count).to eq(1)
      end
    end
  end

  describe '.shutdown!' do
    let(:mock_nc) { double('NATS::Client', connected?: true, close: nil) }

    before do
      allow(JetstreamBridge::Connection).to receive(:nc).and_return(mock_nc)
      allow(JetstreamBridge::Logging).to receive(:info)
      allow(JetstreamBridge::Logging).to receive(:error)
    end

    context 'when connection is initialized' do
      before do
        described_class.instance_variable_set(:@connection_initialized, true)
      end

      it 'closes the NATS connection' do
        described_class.shutdown!
        expect(mock_nc).to have_received(:close)
      end

      it 'logs successful shutdown' do
        described_class.shutdown!
        expect(JetstreamBridge::Logging).to have_received(:info).with(
          'JetStream Bridge shut down gracefully',
          tag: 'JetstreamBridge'
        )
      end

      it 'resets connection_initialized flag' do
        described_class.shutdown!
        expect(described_class.instance_variable_get(:@connection_initialized)).to be false
      end

      it 'handles errors during shutdown' do
        allow(mock_nc).to receive(:close).and_raise(StandardError, 'Connection error')

        described_class.shutdown!

        expect(JetstreamBridge::Logging).to have_received(:error).with(
          'Error during shutdown: Connection error',
          tag: 'JetstreamBridge'
        )
        expect(described_class.instance_variable_get(:@connection_initialized)).to be false
      end
    end

    context 'when connection is not initialized' do
      before do
        described_class.instance_variable_set(:@connection_initialized, false)
      end

      it 'does nothing' do
        described_class.shutdown!
        expect(mock_nc).not_to have_received(:close)
      end
    end
  end

  describe '.configure_for' do
    before do
      described_class.reset!
    end

    it 'applies preset configuration' do
      described_class.configure_for(:production) do |c|
        c.app_name = 'my_app'
        c.destination_app = 'dest'
      end

      # Preset applies reliability features, not env
      expect(described_class.config.use_outbox).to be true
      expect(described_class.config.use_inbox).to be true
      expect(described_class.config.use_dlq).to be true
      expect(described_class.config.app_name).to eq('my_app')
      expect(described_class.config.preset_applied).to eq(:production)
    end

    it 'applies preset without block' do
      described_class.reset!
      described_class.configure_for(:test)
      expect(described_class.config.use_outbox).to be false
      expect(described_class.config.use_inbox).to be false
      expect(described_class.config.max_deliver).to eq(2)
      expect(described_class.config.preset_applied).to eq(:test)
    end

    it 'applies development preset' do
      described_class.reset!
      described_class.configure_for(:development)
      expect(described_class.config.use_outbox).to be false
      expect(described_class.config.use_dlq).to be false
      expect(described_class.config.max_deliver).to eq(3)
      expect(described_class.config.preset_applied).to eq(:development)
    end

    it 'does not establish connection automatically' do
      connection_count = 0
      allow(JetstreamBridge::Connection).to receive(:connect!) { connection_count += 1 }

      described_class.configure_for(:production) do |c|
        c.app_name = 'my_app'
        c.destination_app = 'dest'
      end

      expect(connection_count).to eq(0)
    end
  end

  describe '.publish!' do
    it 'returns result on success' do
      expect(jts).to receive(:publish).and_return(double(duplicate?: false, error: nil))

      result = described_class.publish!(
        event_type: 'user.created',
        payload: { id: 1 }
      )

      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be true
    end

    it 'raises PublishError on failure' do
      error_obj = StandardError.new('Stream not found')
      error_response = double(
        duplicate?: false,
        error: error_obj
      )
      expect(jts).to receive(:publish).and_return(error_response)

      expect do
        described_class.publish!(
          event_type: 'user.created',
          payload: { id: 1 }
        )
      end.to raise_error(JetstreamBridge::PublishError, /Stream not found/)
    end

    it 'includes event_id and subject in raised error' do
      error_obj = StandardError.new('Publish failed')
      error_response = double(
        duplicate?: false,
        error: error_obj
      )
      expect(jts).to receive(:publish).and_return(error_response)

      begin
        described_class.publish!(
          event_type: 'user.created',
          payload: { id: 1 }
        )
        raise 'Expected PublishError to be raised'
      rescue JetstreamBridge::PublishError => e
        expect(e.event_id).not_to be_nil
        expect(e.subject).not_to be_nil
      end
    end
  end

  describe '.publish_batch' do
    let(:batch_publisher) { instance_double(JetstreamBridge::BatchPublisher) }
    let(:batch_result) do
      double('BatchResult',
             successful_count: 2,
             failed_count: 0,
             results: [])
    end

    before do
      allow(JetstreamBridge::BatchPublisher).to receive(:new).and_return(batch_publisher)
      allow(batch_publisher).to receive(:add)
      allow(batch_publisher).to receive(:publish).and_return(batch_result)
    end

    it 'creates batch publisher and yields it' do
      expect(JetstreamBridge::BatchPublisher).to receive(:new).and_return(batch_publisher)

      described_class.publish_batch do |batch|
        expect(batch).to eq(batch_publisher)
      end
    end

    it 'calls publish on batch publisher' do
      expect(batch_publisher).to receive(:publish).and_return(batch_result)

      result = described_class.publish_batch do |batch|
        batch.add(event_type: 'user.created', payload: { id: 1 })
        batch.add(event_type: 'user.updated', payload: { id: 2 })
      end

      expect(result).to eq(batch_result)
    end

    it 'works without block' do
      result = described_class.publish_batch
      expect(result).to eq(batch_result)
    end

    it 'returns batch result with counts' do
      result = described_class.publish_batch do |batch|
        batch.add(event_type: 'test.event', payload: {})
      end

      expect(result.successful_count).to eq(2)
      expect(result.failed_count).to eq(0)
    end
  end

  describe '.health_check edge cases' do
    let(:conn_instance) do
      double('Connection',
             connected?: true,
             connected_at: nil,
             state: :connected,
             last_reconnect_error: nil,
             last_reconnect_error_at: nil)
    end

    let(:mock_nc) { double('NATS::Client', rtt: 0.005) }

    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.*']),
             state: double(messages: 0))
    end

    before do
      allow(JetstreamBridge::Connection).to receive(:instance).and_return(conn_instance)
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
      allow(JetstreamBridge::Connection).to receive(:nc).and_return(mock_nc)
      allow(jts).to receive(:stream_info).and_return(stream_info_data)
    end

    it 'handles nil connected_at timestamp' do
      result = described_class.health_check
      expect(result[:connection][:connected_at]).to be_nil
    end

    it 'handles stream with zero messages' do
      result = described_class.health_check
      expect(result[:stream][:messages]).to eq(0)
    end
  end
end
