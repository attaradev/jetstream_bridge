# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge do
  let(:jts) { double('jetstream', publish: double(duplicate?: false, error: nil)) }

  before do
    described_class.reset!
    allow(JetstreamBridge::Topology).to receive(:ensure!)

    # Configure
    described_class.configure do |c|
      c.destination_app = 'dest'
      c.app_name = 'source'
      c.stream_name = 'test-jetstream-bridge-stream'
    end

    # Set up facade with mocked connection manager
    setup_facade_mocks(jts)
  end

  after do
    described_class.reset!
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

    it 'returns consumer instance' do
      consumer = described_class.subscribe { nil }
      expect(consumer).to be_a(JetstreamBridge::Consumer)
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
    let(:mock_nc) { double('NATS::Client', rtt: 0.005, flush: nil) }

    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.*']),
             state: double(messages: 42))
    end

    before do
      # Enable JS API for health check tests that need stream info
      described_class.config.disable_js_api = false

      # Update the connection manager mock to include nats_client
      mock_connection_manager = instance_double(
        JetstreamBridge::ConnectionManager,
        jetstream: jts,
        nats_client: mock_nc,
        connected?: true,
        connect!: nil,
        disconnect!: nil,
        health_check: {
          connected: true,
          state: :connected,
          connected_at: Time.utc(2024, 1, 1, 12, 0, 0),
          last_error: nil,
          last_error_at: nil
        }
      )

      facade = described_class.instance_variable_get(:@facade)
      facade.instance_variable_set(:@connection_manager, mock_connection_manager)

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
      expect(result[:connection][:connected_at]).to eq(Time.utc(2024, 1, 1, 12, 0, 0))
    end

    it 'includes stream information' do
      result = described_class.health_check
      expect(result[:stream][:exists]).to be true
      expect(result[:stream][:subjects]).to eq(['test.*'])
      expect(result[:stream][:messages]).to eq(42)
    end

    it 'includes config information' do
      result = described_class.health_check
      expect(result[:config][:env]).to be_nil
      expect(result[:config][:app_name]).to eq('source')
      expect(result[:config][:destination_app]).to eq('dest')
    end

    it 'includes version' do
      result = described_class.health_check
      expect(result[:version]).to eq(JetstreamBridge::VERSION)
    end

    context 'when not connected' do
      before do
        mock_connection_manager = instance_double(
          JetstreamBridge::ConnectionManager,
          jetstream: nil,
          nats_client: nil,
          connected?: false,
          health_check: {
            connected: false,
            state: :disconnected,
            connected_at: nil,
            last_error: nil,
            last_error_at: nil
          }
        )

        facade = described_class.instance_variable_get(:@facade)
        facade.instance_variable_set(:@connection_manager, mock_connection_manager)
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
        mock_connection_manager = instance_double(
          JetstreamBridge::ConnectionManager
        )
        allow(mock_connection_manager).to receive(:health_check).and_raise(StandardError, 'Connection error')

        facade = described_class.instance_variable_get(:@facade)
        facade.instance_variable_set(:@connection_manager, mock_connection_manager)
      end

      it 'returns error hash' do
        result = described_class.health_check
        expect(result[:healthy]).to be false
        expect(result[:error]).to eq('StandardError: Connection error')
      end
    end
  end

  describe '.connected?' do
    it 'returns true when connected' do
      # Already mocked as connected in before block
      expect(described_class.connected?).to be true
    end

    it 'returns false when not connected' do
      # Reset and don't set up facade
      described_class.reset!
      expect(described_class.connected?).to be false
    end

    it 'returns false on error' do
      # Mock connection_manager to raise error
      facade = described_class.instance_variable_get(:@facade)
      connection_manager = facade.instance_variable_get(:@connection_manager)
      allow(connection_manager).to receive(:connected?).and_raise(StandardError)
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
      # Enable JS API for stream_info tests
      described_class.config.disable_js_api = false
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

    context 'when connection manager not set up' do
      before do
        described_class.reset!
        described_class.configure do |c|
          c.destination_app = 'dest'
          c.app_name = 'source'
          c.stream_name = 'test-jetstream-bridge-stream'
          c.disable_js_api = false
        end

        # Set up mocks after reset
        setup_facade_mocks(jts)
        allow(jts).to receive(:stream_info).and_return(stream_info_data)
      end

      it 'returns stream info through the facade' do
        result = described_class.stream_info
        expect(result[:exists]).to be true
      end
    end
  end

  describe '.configure' do
    before do
      # Reset and clear mocks from top-level before block
      described_class.reset!
    end

    it 'accepts block configuration' do
      described_class.configure do |c|
        c.env = 'staging'
        c.app_name = 'test'
      end
      expect(described_class.config.env).to eq('staging')
      expect(described_class.config.app_name).to eq('test')
    end

    it 'returns config instance' do
      config = described_class.configure do |c|
        c.env = 'test'
      end

      expect(config).to be_a(JetstreamBridge::Config)
    end
  end

  describe '.reset!' do
    it 'clears the facade (which includes configuration and connection)' do
      described_class.configure { |c| c.env = 'custom' }
      described_class.reset!
      # After reset, a new facade is created with fresh config
      expect(described_class.config.env).to be_nil
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

  describe '.health_check edge cases' do
    let(:mock_nc) { double('NATS::Client', rtt: 0.005, flush: nil) }

    let(:stream_info_data) do
      double('StreamInfo',
             config: double(subjects: ['test.*']),
             state: double(messages: 0))
    end

    before do
      described_class.config.disable_js_api = false

      mock_connection_manager = instance_double(
        JetstreamBridge::ConnectionManager,
        jetstream: jts,
        nats_client: mock_nc,
        connected?: true,
        health_check: {
          connected: true,
          state: :connected,
          connected_at: nil,
          last_error: nil,
          last_error_at: nil
        }
      )

      facade = described_class.instance_variable_get(:@facade)
      facade.instance_variable_set(:@connection_manager, mock_connection_manager)

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
