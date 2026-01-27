# frozen_string_literal: true

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
    allow(JetstreamBridge::Topology).to receive(:ensure!).and_return(nil)
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

  describe '#ensure!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.ensure!(jts: mock_jts)
      end

      it 'ensures stream topology' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        provisioner.ensure!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.ensure!
      end

      it 'ensures stream topology with new connection' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        provisioner.ensure!
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure!
        expect(result).to eq(mock_jts)
      end
    end

    context 'when ensure_consumer is true (default)' do
      it 'creates both stream and consumer' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)

        provisioner.ensure!(jts: mock_jts)
      end

      it 'logs successful provisioning with stream and consumer' do
        allow(JetstreamBridge::Logging).to receive(:info).and_call_original
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            /Provisioned stream=test-stream consumer=test-consumer/,
            tag: 'JetstreamBridge::Provisioner'
          ).and_call_original
        provisioner.ensure!(jts: mock_jts)
      end
    end

    context 'when ensure_consumer is false' do
      it 'creates only stream without consumer' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        expect(mock_subscription_manager).not_to receive(:ensure_consumer!)

        provisioner.ensure!(jts: mock_jts, ensure_consumer: false)
      end

      it 'logs successful provisioning without consumer mention' do
        allow(JetstreamBridge::Logging).to receive(:info).and_call_original
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            /Provisioned stream=test-stream consumer=$/,
            tag: 'JetstreamBridge::Provisioner'
          ).and_call_original
        provisioner.ensure!(jts: mock_jts, ensure_consumer: false)
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure!(jts: mock_jts, ensure_consumer: false)
        expect(result).to eq(mock_jts)
      end
    end
  end

  describe '#ensure_stream!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.ensure_stream!(jts: mock_jts)
      end

      it 'ensures stream topology' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        provisioner.ensure_stream!(jts: mock_jts)
      end

      it 'logs stream creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Stream ensured: test-stream',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.ensure_stream!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure_stream!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.ensure_stream!
      end

      it 'ensures stream topology with new connection' do
        expect(JetstreamBridge::Topology).to receive(:ensure!).with(mock_jts)
        provisioner.ensure_stream!
      end

      it 'logs stream creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Stream ensured: test-stream',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.ensure_stream!
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure_stream!
        expect(result).to eq(mock_jts)
      end
    end
  end

  describe '#ensure_consumer!' do
    let(:provisioner) { described_class.new }

    context 'when jts parameter is provided' do
      it 'uses the provided JetStream context' do
        expect(JetstreamBridge::Connection).not_to receive(:connect!)
        provisioner.ensure_consumer!(jts: mock_jts)
      end

      it 'creates consumer with force flag' do
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)
        provisioner.ensure_consumer!(jts: mock_jts)
      end

      it 'logs consumer creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Consumer ensured: test-consumer',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.ensure_consumer!(jts: mock_jts)
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure_consumer!(jts: mock_jts)
        expect(result).to eq(mock_jts)
      end
    end

    context 'when jts parameter is not provided' do
      it 'creates new connection with verify_js true' do
        expect(JetstreamBridge::Connection).to receive(:connect!)
          .with(verify_js: true)
          .and_return(mock_jts)
        provisioner.ensure_consumer!
      end

      it 'creates consumer with new connection' do
        expect(JetstreamBridge::SubscriptionManager).to receive(:new)
          .with(mock_jts, 'test-consumer', mock_config)
          .and_return(mock_subscription_manager)
        expect(mock_subscription_manager).to receive(:ensure_consumer!).with(force: true)
        provisioner.ensure_consumer!
      end

      it 'logs consumer creation' do
        expect(JetstreamBridge::Logging).to receive(:info)
          .with(
            'Consumer ensured: test-consumer',
            tag: 'JetstreamBridge::Provisioner'
          )
        provisioner.ensure_consumer!
      end

      it 'returns the JetStream context' do
        result = provisioner.ensure_consumer!
        expect(result).to eq(mock_jts)
      end
    end
  end
end
