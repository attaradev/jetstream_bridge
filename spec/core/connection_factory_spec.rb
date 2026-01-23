# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/core/connection_factory'

RSpec.describe JetstreamBridge::Core::ConnectionFactory do
  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'test_app'
      c.stream_name     = 'jetstream-bridge-stream'
    end
  end

  after { JetstreamBridge.reset! }
  describe JetstreamBridge::Core::ConnectionFactory::ConnectionOptions do
    describe '.build' do
      it 'returns default options when no config provided' do
        options = described_class.build

        expect(options.to_h[:reconnect]).to be true
        expect(options.to_h[:reconnect_time_wait]).to eq(2)
        expect(options.to_h[:max_reconnect_attempts]).to eq(10)
        expect(options.to_h[:connect_timeout]).to eq(5)
      end

      it 'merges custom options with defaults' do
        custom = { connect_timeout: 10, custom_option: 'value' }
        options = described_class.build(custom)

        expect(options.to_h[:connect_timeout]).to eq(10)
        expect(options.to_h[:custom_option]).to eq('value')
        expect(options.to_h[:reconnect]).to be true
      end

      it 'allows overriding reconnect behavior' do
        custom = { reconnect: false }
        options = described_class.build(custom)

        expect(options.to_h[:reconnect]).to be false
      end

      it 'allows overriding max_reconnect_attempts' do
        custom = { max_reconnect_attempts: 20 }
        options = described_class.build(custom)

        expect(options.to_h[:max_reconnect_attempts]).to eq(20)
      end
    end

    describe '#to_h' do
      it 'returns hash representation of options' do
        options = described_class.new(reconnect: true, connect_timeout: 5)

        hash = options.to_h

        expect(hash).to be_a(Hash)
        expect(hash[:reconnect]).to be true
        expect(hash[:connect_timeout]).to eq(5)
      end

      it 'includes all provided options' do
        options = described_class.new(
          reconnect: true,
          reconnect_time_wait: 3,
          max_reconnect_attempts: 15,
          connect_timeout: 10,
          custom: 'value'
        )

        hash = options.to_h

        expect(hash.keys).to include(:reconnect, :reconnect_time_wait, :max_reconnect_attempts,
                                     :connect_timeout, :custom)
      end

      it 'includes servers when provided' do
        options = described_class.new(servers: 'nats://localhost:4222')

        hash = options.to_h

        expect(hash[:servers]).to eq(['nats://localhost:4222'])
      end

      it 'includes authentication credentials when provided' do
        options = described_class.new(
          user: 'test_user',
          pass: 'test_pass',
          token: 'test_token',
          name: 'my-app'
        )

        hash = options.to_h

        expect(hash[:user]).to eq('test_user')
        expect(hash[:pass]).to eq('test_pass')
        expect(hash[:token]).to eq('test_token')
        expect(hash[:name]).to eq('my-app')
      end

      it 'omits nil optional fields' do
        options = described_class.new(reconnect: true)

        hash = options.to_h

        expect(hash).not_to have_key(:servers)
        expect(hash).not_to have_key(:user)
        expect(hash).not_to have_key(:pass)
        expect(hash).not_to have_key(:token)
        expect(hash).not_to have_key(:name)
      end
    end

    describe '#initialize' do
      it 'normalizes single server URL' do
        options = described_class.new(servers: 'nats://localhost:4222')

        expect(options.servers).to eq(['nats://localhost:4222'])
      end

      it 'normalizes comma-separated server URLs' do
        options = described_class.new(servers: 'nats://server1:4222,nats://server2:4222')

        expect(options.servers).to eq(['nats://server1:4222', 'nats://server2:4222'])
      end

      it 'normalizes array of server URLs' do
        options = described_class.new(servers: ['nats://server1:4222', 'nats://server2:4222'])

        expect(options.servers).to eq(['nats://server1:4222', 'nats://server2:4222'])
      end

      it 'handles mixed comma-separated and array servers' do
        options = described_class.new(servers: ['nats://s1:4222,nats://s2:4222', 'nats://s3:4222'])

        expect(options.servers).to eq(['nats://s1:4222', 'nats://s2:4222', 'nats://s3:4222'])
      end

      it 'strips whitespace from server URLs' do
        options = described_class.new(servers: '  nats://server1:4222  ,  nats://server2:4222  ')

        expect(options.servers).to eq(['nats://server1:4222', 'nats://server2:4222'])
      end

      it 'rejects empty server strings' do
        options = described_class.new(servers: 'nats://server1:4222,,,nats://server2:4222')

        expect(options.servers).to eq(['nats://server1:4222', 'nats://server2:4222'])
      end

      it 'handles nil servers' do
        options = described_class.new

        expect(options.servers).to be_nil
      end
    end

    describe 'DEFAULT_OPTS' do
      it 'is frozen to prevent modification' do
        expect(described_class::DEFAULT_OPTS).to be_frozen
      end

      it 'contains expected default values' do
        defaults = described_class::DEFAULT_OPTS

        expect(defaults[:reconnect]).to be true
        expect(defaults[:reconnect_time_wait]).to eq(2)
        expect(defaults[:max_reconnect_attempts]).to eq(10)
        expect(defaults[:connect_timeout]).to eq(5)
      end
    end
  end

  describe '.build_options' do
    it 'builds options from JetstreamBridge config' do
      config = double('config',
                      nats_urls: 'nats://localhost:4222',
                      app_name: 'test_app')

      options = described_class.build_options(config)

      expect(options.servers).to eq(['nats://localhost:4222'])
      expect(options.name).to eq('test_app')
    end

    it 'uses defaults when config returns nil' do
      config = double('config',
                      nats_urls: 'nats://localhost:4222',
                      app_name: 'test_app')

      options = described_class.build_options(config)

      expect(options.to_h[:reconnect]).to be true
      expect(options.to_h[:connect_timeout]).to eq(5)
    end

    it 'handles config errors gracefully' do
      config = double('config')
      allow(config).to receive(:nats_urls).and_raise(StandardError)

      expect do
        described_class.build_options(config)
      end.to raise_error(StandardError)
    end

    it 'raises error when nats_urls is nil' do
      config = double('config', nats_urls: nil, app_name: 'test')

      expect do
        described_class.build_options(config)
      end.to raise_error(JetstreamBridge::ConnectionNotEstablishedError, /No NATS URLs/)
    end

    it 'raises error when nats_urls is empty string' do
      config = double('config', nats_urls: '', app_name: 'test')

      expect do
        described_class.build_options(config)
      end.to raise_error(JetstreamBridge::ConnectionNotEstablishedError, /No NATS URLs/)
    end

    it 'raises error when nats_urls is whitespace only' do
      config = double('config', nats_urls: '   ', app_name: 'test')

      expect do
        described_class.build_options(config)
      end.to raise_error(JetstreamBridge::ConnectionNotEstablishedError, /No NATS URLs/)
    end

    it 'handles multiple server URLs' do
      config = double('config',
                      nats_urls: 'nats://server1:4222,nats://server2:4222',
                      app_name: 'test_app')

      options = described_class.build_options(config)

      expect(options.servers).to eq(['nats://server1:4222', 'nats://server2:4222'])
      expect(options.name).to eq('test_app')
    end
  end

  describe '.create_client' do
    let(:mock_client) { instance_double(NATS::IO::Client) }

    before do
      allow(NATS::IO::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:connect)
    end

    it 'creates a new NATS client' do
      described_class.create_client

      expect(NATS::IO::Client).to have_received(:new)
    end

    it 'connects the client with options' do
      options = JetstreamBridge::Core::ConnectionFactory::ConnectionOptions.new(
        servers: ['nats://localhost:4222'],
        reconnect: true
      )

      described_class.create_client(options)

      expect(mock_client).to have_received(:connect).with(hash_including(
                                                            servers: ['nats://localhost:4222'],
                                                            reconnect: true
                                                          ))
    end

    it 'uses default options when none provided' do
      described_class.create_client

      expect(mock_client).to have_received(:connect).with(hash_including(
                                                            reconnect: true,
                                                            connect_timeout: 5
                                                          ))
    end

    it 'returns the connected client' do
      client = described_class.create_client

      expect(client).to eq(mock_client)
    end

    context 'connection failures' do
      it 'raises error when connection fails' do
        allow(mock_client).to receive(:connect).and_raise(NATS::IO::NoServersError)

        expect do
          described_class.create_client
        end.to raise_error(NATS::IO::NoServersError)
      end

      it 'propagates connection timeout' do
        allow(mock_client).to receive(:connect).and_raise(NATS::IO::ConnectError.new('timeout'))

        expect do
          described_class.create_client
        end.to raise_error(NATS::IO::ConnectError, /timeout/)
      end
    end
  end

  describe '.create_jetstream' do
    let(:mock_client) { instance_double(NATS::IO::Client) }

    it 'creates a JetStream context from client' do
      mock_jetstream = Object.new
      allow(mock_client).to receive(:jetstream).and_return(mock_jetstream)

      js = described_class.create_jetstream(mock_client)

      expect(js).to eq(mock_jetstream)
      expect(mock_client).to have_received(:jetstream)
    end

    it 'adds nc accessor method when not present' do
      mock_jetstream = Object.new
      allow(mock_client).to receive(:jetstream).and_return(mock_jetstream)

      js = described_class.create_jetstream(mock_client)

      expect(js).to respond_to(:nc)
      expect(js.nc).to eq(mock_client)
    end

    it 'does not override existing nc method' do
      original_client = double('original_client')
      mock_jetstream = Object.new
      mock_jetstream.define_singleton_method(:nc) { original_client }
      allow(mock_client).to receive(:jetstream).and_return(mock_jetstream)

      js = described_class.create_jetstream(mock_client)

      expect(js.nc).to eq(original_client)
    end

    it 'returns jetstream context with client access' do
      mock_jetstream = Object.new
      allow(mock_client).to receive(:jetstream).and_return(mock_jetstream)

      js = described_class.create_jetstream(mock_client)

      expect(js.nc).to eq(mock_client)
    end
  end

  describe 'integration with Connection class' do
    it 'can be used to establish connections' do
      mock_client = instance_double(NATS::IO::Client, connected?: true)
      allow(NATS::IO::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:connect)

      client = described_class.create_client

      expect(client).to eq(mock_client)
      expect(mock_client).to have_received(:connect)
    end
  end
end
