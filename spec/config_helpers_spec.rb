# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'jetstream_bridge/config_helpers'

RSpec.describe JetstreamBridge::ConfigHelpers do
  describe '.configure_bidirectional' do
    let(:config) { JetstreamBridge::Config.new }
    let(:logger) { instance_double(Logger) }

    before do
      allow(JetstreamBridge).to receive(:config).and_return(config)
    end

    it 'applies defaults for non-restrictive mode' do
      described_class.configure_bidirectional(
        app_name: 'system_a',
        destination_app: 'system_b',
        stream_name: 'sync-stream',
        nats_url: 'nats://example:4222',
        logger: logger
      )

      expect(config.app_name).to eq('system_a')
      expect(config.destination_app).to eq('system_b')
      expect(config.stream_name).to eq('sync-stream')
      expect(config.nats_urls).to eq('nats://example:4222')
      expect(config.auto_provision).to be true
      expect(config.use_inbox).to be true
      expect(config.use_outbox).to be true
      expect(config.max_deliver).to eq(5)
      expect(config.ack_wait).to eq('30s')
      expect(config.backoff).to eq(%w[1s 5s 15s 30s 60s])
      expect(config.logger).to eq(logger)
    end

    it 'applies overrides and restrictive mode' do
      described_class.configure_bidirectional(
        app_name: 'system_b',
        destination_app: 'system_a',
        stream_name: 'custom-stream',
        nats_url: 'nats://custom:4222',
        mode: :restrictive,
        max_deliver: 10,
        ack_wait: '10s',
        backoff: %w[1s 2s],
        consumer_mode: :push
      )

      expect(config.auto_provision).to be false
      expect(config.stream_name).to eq('custom-stream')
      expect(config.nats_urls).to eq('nats://custom:4222')
      expect(config.max_deliver).to eq(10)
      expect(config.ack_wait).to eq('10s')
      expect(config.backoff).to eq(%w[1s 2s])
      expect(config.consumer_mode).to eq(:push)
    end
  end

  describe '.setup_rails_lifecycle' do
    it 'hooks into Rails after_initialize and registers shutdown' do
      startup_called = false
      shutdown_called = false

      fake_config = double('RailsConfig')
      allow(fake_config).to receive(:after_initialize).and_yield
      fake_app = double('RailsApp', config: fake_config)
      fake_env = double('Env', development?: false)

      stub_const('Rails', double('Rails', application: fake_app, logger: nil, env: fake_env))

      allow(JetstreamBridge).to receive(:startup!) { startup_called = true }
      allow(JetstreamBridge).to receive(:shutdown!) { shutdown_called = true }
      allow(Kernel).to receive(:at_exit).and_yield

      described_class.setup_rails_lifecycle(logger: nil, rails_app: fake_app)

      expect(startup_called).to be true
      expect(shutdown_called).to be true
    end
  end
end
