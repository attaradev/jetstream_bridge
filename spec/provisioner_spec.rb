# frozen_string_literal: true

require 'logger'
require 'spec_helper'

RSpec.describe JetstreamBridge::Provisioner do
  let(:mock_jts) { double('JetStream') }
  let(:mock_config) do
    instance_double(
      JetstreamBridge::Config,
      stream_name: 'test-stream',
      durable_name: 'test-consumer',
      logger: nil
    )
  end
  let(:mock_subscription_manager) do
    instance_double(JetstreamBridge::SubscriptionManager)
  end

  before do
    allow(JetstreamBridge).to receive(:config).and_return(mock_config)
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(mock_jts)
    allow(JetstreamBridge::Topology).to receive(:provision!).and_return(nil)
    allow(JetstreamBridge::Stream).to receive(:ensure!).and_return(nil)
    allow(JetstreamBridge::SubscriptionManager).to receive(:new).and_return(mock_subscription_manager)
    allow(mock_subscription_manager).to receive(:ensure_consumer!)
  end

  describe '#initialize' do
    it 'uses default config when none provided' do
      provisioner = described_class.new
      expect(provisioner.instance_variable_get(:@config)).to eq(mock_config)
    end

    it 'accepts custom config' do
      custom_config = instance_double(
        JetstreamBridge::Config,
        stream_name: 'custom-stream',
        durable_name: 'custom-consumer'
      )
      provisioner = described_class.new(config: custom_config)
      expect(provisioner.instance_variable_get(:@config)).to eq(custom_config)
    end
  end

  describe '#provision!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.provision!(jts: mock_jts)
      end

      it 'provisions stream topology' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        provisioner.provision!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.provision!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.provision!
      end

      it 'provisions stream topology with new connection' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        provisioner.provision!
      end

      it 'returns the JetStream context' do
        result = provisioner.provision!
        expect(result).to eq(mock_jts)
      end
    end

    context 'when provision_consumer is true (default)' do
      it 'creates both stream and consumer' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)

        provisioner.provision!(jts: mock_jts)
      end

      it 'logs successful provisioning with stream and consumer' do
        allow(JetstreamBridge::Logging).to receive(:info).and_call_original
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            /Provisioned stream=test-stream consumer=test-consumer/,
            tag: 'JetstreamBridge::Provisioner'
          ).and_call_original
        provisioner.provision!(jts: mock_jts)
      end
    end

    context 'when provision_consumer is false' do
      it 'creates only stream without consumer' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        expect(mock_subscription_manager).not_to receive(:ensure_consumer!)

        provisioner.provision!(jts: mock_jts, provision_consumer: false)
      end

      it 'logs successful provisioning without consumer mention' do
        allow(JetstreamBridge::Logging).to receive(:info).and_call_original
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            /Provisioned stream=test-stream consumer=$/,
            tag: 'JetstreamBridge::Provisioner'
          ).and_call_original
        provisioner.provision!(jts: mock_jts, provision_consumer: false)
      end

      it 'returns the JetStream context' do
        result = provisioner.provision!(jts: mock_jts, provision_consumer: false)
        expect(result).to eq(mock_jts)
      end
    end
  end

  describe '#provision_stream!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.provision_stream!(jts: mock_jts)
      end

      it 'provisions stream topology' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        provisioner.provision_stream!(jts: mock_jts)
      end

      it 'logs stream creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Stream provisioned: test-stream',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.provision_stream!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.provision_stream!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.provision_stream!
      end

      it 'provisions stream topology with new connection' do
        expect(JetstreamBridge::Topology).to receive(:provision!).with(mock_jts)
        provisioner.provision_stream!
      end

      it 'logs stream creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Stream provisioned: test-stream',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.provision_stream!
      end

      it 'returns the JetStream context' do
        result = provisioner.provision_stream!
        expect(result).to eq(mock_jts)
      end
    end
  end

  describe '#provision_consumer!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.provision_consumer!(jts: mock_jts)
      end

      it 'creates consumer with force flag' do
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)
        provisioner.provision_consumer!(jts: mock_jts)
      end

      it 'logs consumer creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Consumer provisioned: test-consumer',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.provision_consumer!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.provision_consumer!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.provision_consumer!
      end

      it 'creates consumer with new connection' do
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)
        provisioner.provision_consumer!
      end

      it 'logs consumer creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Consumer provisioned: test-consumer',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.provision_consumer!
      end

      it 'returns the JetStream context' do
        result = provisioner.provision_consumer!
        expect(result).to eq(mock_jts)
      end
    end
  end

  describe '.provision_bidirectional!' do
    let(:logger) { instance_double(Logger, info: nil) }
    let(:provisioner_a) { instance_double(described_class, provision!: true) }
    let(:provisioner_b) { instance_double(described_class, provision!: true) }
    let(:configs) { [] }
    def with_env(env)
      old = {}
      env.each_key { |k| old[k] = ENV.fetch(k, nil) }
      env.each { |k, v| ENV[k] = v }
      yield
    ensure
      env.each_key do |k|
        old[k].nil? ? ENV.delete(k) : ENV[k] = old[k]
      end
    end

    before do
      allow(described_class).to receive(:new).and_return(provisioner_a, provisioner_b)
      allow(JetstreamBridge).to receive(:configure) do |&blk|
        cfg = JetstreamBridge::Config.new
        configs << cfg
        blk.call(cfg)
        cfg
      end
      allow(JetstreamBridge).to receive(:startup!)
      allow(JetstreamBridge).to receive(:shutdown!)
    end

    it 'provisions both directions with shared settings' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        stream_name: 'sync-stream',
        nats_url: 'nats://example:4222',
        logger: logger,
        max_deliver: 9,
        ack_wait: '10s',
        backoff: %w[1s 2s]
      )

      expect(described_class).to have_received(:new).twice
      expect(JetstreamBridge).to have_received(:startup!).twice
      expect(JetstreamBridge).to have_received(:shutdown!).twice

      expect(configs.map(&:app_name)).to eq(%w[system_a system_b])
      expect(configs.map(&:destination_app)).to eq(%w[system_b system_a])
      expect(configs.map(&:auto_provision)).to all(be true)
      expect(configs.map(&:use_inbox)).to all(be false)
      expect(configs.map(&:use_outbox)).to all(be false)
      expect(configs.map(&:max_deliver)).to all(eq(9))
      expect(configs.map(&:ack_wait)).to all(eq('10s'))
      expect(configs.map(&:backoff)).to all(eq(%w[1s 2s]))
      expect(configs.map(&:nats_urls)).to all(eq('nats://example:4222'))
    end

    it 'applies per-app consumer modes when provided' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        consumer_modes: { 'system_a' => :push, 'system_b' => :pull }
      )

      expect(configs.map(&:consumer_mode)).to eq([:push, :pull])
    end

    it 'falls back to shared consumer_mode when per-app map absent' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        consumer_mode: :push
      )

      expect(configs.map(&:consumer_mode)).to eq([:push, :push])
    end

    it 'ignores consumer_mode in shared_config to preserve per-app mode' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        consumer_modes: { 'system_a' => :pull, 'system_b' => :push },
        consumer_mode: :pull, # shared fallback
        max_deliver: 5,       # arbitrary shared config to ensure merge still works
        backoff: %w[1s]       # arbitrary
      )

      expect(configs.map(&:consumer_mode)).to eq([:pull, :push])
      expect(configs.map(&:backoff)).to all(eq(%w[1s]))
    end

    it 'defaults missing per-app entry to shared consumer_mode' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        consumer_modes: { 'system_a' => :push },
        consumer_mode: :pull
      )

      expect(configs.map(&:consumer_mode)).to eq([:push, :pull])
    end

    it 'derives per-app modes from CONSUMER_MODES env when not provided explicitly' do
      with_env('CONSUMER_MODES' => 'system_a:push,system_b:pull', 'CONSUMER_MODE' => 'pull') do
        described_class.provision_bidirectional!(
          app_a: 'system_a',
          app_b: 'system_b'
        )
      end

      expect(configs.map(&:consumer_mode)).to eq([:push, :pull])
    end

    it 'falls back to shared CONSUMER_MODE env when map missing' do
      with_env('CONSUMER_MODE' => 'push') do
        described_class.provision_bidirectional!(
          app_a: 'system_a',
          app_b: 'system_b'
        )
      end

      expect(configs.map(&:consumer_mode)).to eq([:push, :push])
    end

    it 'normalizes consumer_modes hash values given as strings and symbols' do
      described_class.provision_bidirectional!(
        app_a: 'system_a',
        app_b: 'system_b',
        consumer_modes: { system_a: 'push' },
        consumer_mode: 'pull'
      )

      expect(configs.map(&:consumer_mode)).to eq([:push, :pull])
    end
  end
end
