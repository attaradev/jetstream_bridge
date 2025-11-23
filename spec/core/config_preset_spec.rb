# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/core/config_preset'

RSpec.describe JetstreamBridge::ConfigPreset do
  let(:config) { JetstreamBridge::Config.new }

  describe '.apply' do
    it 'raises error for unknown preset' do
      expect do
        described_class.apply(config, :unknown_preset)
      end.to raise_error(ArgumentError, /Unknown preset/)
    end
  end

  describe 'development preset' do
    before { described_class.apply(config, :development) }

    it 'disables outbox' do
      expect(config.use_outbox).to be(false)
    end

    it 'disables inbox' do
      expect(config.use_inbox).to be(false)
    end

    it 'disables DLQ' do
      expect(config.use_dlq).to be(false)
    end

    it 'sets low max_deliver' do
      expect(config.max_deliver).to eq(3)
    end

    it 'sets short ack_wait' do
      expect(config.ack_wait).to eq('10s')
    end

    it 'sets minimal backoff' do
      expect(config.backoff).to eq(%w[1s 2s 5s])
    end
  end

  describe 'test preset' do
    before { described_class.apply(config, :test) }

    it 'disables outbox' do
      expect(config.use_outbox).to be(false)
    end

    it 'disables inbox' do
      expect(config.use_inbox).to be(false)
    end

    it 'disables DLQ' do
      expect(config.use_dlq).to be(false)
    end

    it 'sets minimal max_deliver' do
      expect(config.max_deliver).to eq(2)
    end

    it 'sets very short ack_wait' do
      expect(config.ack_wait).to eq('5s')
    end

    it 'sets fast backoff' do
      expect(config.backoff).to eq(%w[0.1s 0.5s])
    end
  end

  describe 'production preset' do
    before { described_class.apply(config, :production) }

    it 'enables outbox' do
      expect(config.use_outbox).to be(true)
    end

    it 'enables inbox' do
      expect(config.use_inbox).to be(true)
    end

    it 'enables DLQ' do
      expect(config.use_dlq).to be(true)
    end

    it 'sets reasonable max_deliver' do
      expect(config.max_deliver).to eq(5)
    end

    it 'sets reasonable ack_wait' do
      expect(config.ack_wait).to eq('30s')
    end

    it 'sets progressive backoff' do
      expect(config.backoff).to eq(%w[1s 5s 15s 30s 60s])
    end
  end

  describe 'staging preset' do
    before { described_class.apply(config, :staging) }

    it 'enables outbox' do
      expect(config.use_outbox).to be(true)
    end

    it 'enables inbox' do
      expect(config.use_inbox).to be(true)
    end

    it 'enables DLQ' do
      expect(config.use_dlq).to be(true)
    end

    it 'sets moderate max_deliver' do
      expect(config.max_deliver).to eq(3)
    end

    it 'sets shorter ack_wait than production' do
      expect(config.ack_wait).to eq('15s')
    end
  end

  describe 'high_throughput preset' do
    before { described_class.apply(config, :high_throughput) }

    it 'disables outbox for speed' do
      expect(config.use_outbox).to be(false)
    end

    it 'disables inbox for speed' do
      expect(config.use_inbox).to be(false)
    end

    it 'enables DLQ' do
      expect(config.use_dlq).to be(true)
    end

    it 'sets low max_deliver' do
      expect(config.max_deliver).to eq(3)
    end

    it 'sets short ack_wait' do
      expect(config.ack_wait).to eq('10s')
    end

    it 'sets aggressive backoff' do
      expect(config.backoff).to eq(%w[1s 2s 5s])
    end
  end

  describe 'maximum_reliability preset' do
    before { described_class.apply(config, :maximum_reliability) }

    it 'enables outbox' do
      expect(config.use_outbox).to be(true)
    end

    it 'enables inbox' do
      expect(config.use_inbox).to be(true)
    end

    it 'enables DLQ' do
      expect(config.use_dlq).to be(true)
    end

    it 'sets high max_deliver' do
      expect(config.max_deliver).to eq(10)
    end

    it 'sets long ack_wait' do
      expect(config.ack_wait).to eq('60s')
    end

    it 'sets extensive backoff' do
      expect(config.backoff).to eq(%w[1s 5s 15s 30s 60s 120s 300s 600s 1200s 1800s])
    end
  end

  describe 'config integration' do
    it 'tracks applied preset' do
      config.apply_preset(:production)
      expect(config.preset_applied).to eq(:production)
    end

    it 'allows symbol or string preset name' do
      config.apply_preset('development')
      expect(config.preset_applied).to eq(:development)
    end

    it 'returns config for chaining' do
      result = config.apply_preset(:production)
      expect(result).to eq(config)
    end
  end
end
