# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::SubscriptionManager do
  let(:mock_jts) { double('NATS::JetStream') }
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.destination_app = 'dest_app'
      c.app_name = 'test_app'
      c.stream_name = 'test_app-jetstream-bridge-stream'
      c.max_deliver = 5
      c.ack_wait = 30
      c.backoff = [1, 5, 10]
      c.disable_js_api = false
    end
  end
  let(:durable) { 'test_durable' }
  let(:manager) { described_class.new(mock_jts, durable, config) }

  before do
    allow(JetstreamBridge).to receive(:config).and_return(config)
  end

  describe '#initialize' do
    it 'sets the jetstream context' do
      expect(manager.instance_variable_get(:@jts)).to eq(mock_jts)
    end

    it 'sets the durable name' do
      expect(manager.instance_variable_get(:@durable)).to eq(durable)
    end

    it 'builds consumer config' do
      expect(manager.desired_consumer_cfg).to include(
        durable_name: durable,
        filter_subject: 'dest_app.sync.test_app',
        ack_policy: 'explicit',
        deliver_policy: 'all',
        max_deliver: 5
      )
    end
  end

  describe '#stream_name' do
    it 'returns the stream name from config' do
      expect(manager.stream_name).to eq('test_app-jetstream-bridge-stream')
    end
  end

  describe '#filter_subject' do
    it 'returns the destination subject from config' do
      expect(manager.filter_subject).to eq('dest_app.sync.test_app')
    end
  end

  describe '#desired_consumer_cfg' do
    it 'includes durable name' do
      expect(manager.desired_consumer_cfg[:durable_name]).to eq(durable)
    end

    it 'includes filter subject' do
      expect(manager.desired_consumer_cfg[:filter_subject]).to eq('dest_app.sync.test_app')
    end

    it 'includes ack policy' do
      expect(manager.desired_consumer_cfg[:ack_policy]).to eq('explicit')
    end

    it 'includes deliver policy' do
      expect(manager.desired_consumer_cfg[:deliver_policy]).to eq('all')
    end

    it 'includes max_deliver from config' do
      expect(manager.desired_consumer_cfg[:max_deliver]).to eq(5)
    end

    it 'converts ack_wait to nanos' do
      expect(manager.desired_consumer_cfg[:ack_wait]).to eq(30_000_000_000)
    end

    it 'converts backoff array to nanos' do
      expect(manager.desired_consumer_cfg[:backoff]).to eq([1_000_000_000, 5_000_000_000, 10_000_000_000])
    end
  end

  describe '#ensure_consumer!' do
    context 'when JS API disabled' do
      before do
        config.disable_js_api = true
      end

      it 'does nothing except log' do
        expect(mock_jts).not_to receive(:consumer_info)
        expect(mock_jts).not_to receive(:add_consumer)
        expect(mock_jts).not_to receive(:delete_consumer)
        manager.ensure_consumer!
      end
    end

    context 'when consumer does not exist' do
      before do
        allow(mock_jts).to receive(:consumer_info).and_raise(NATS::JetStream::Error)
        allow(mock_jts).to receive(:add_consumer)
      end

      it 'creates a new consumer' do
        expect(mock_jts).to receive(:add_consumer).with(
          config.stream_name,
          hash_including(durable_name: durable)
        )
        manager.ensure_consumer!
      end
    end

    context 'when consumer exists with desired config' do
      let(:mock_config) do
        double('ConsumerConfig',
               filter_subject: 'dest_app.sync.test_app',
               ack_policy: :explicit,
               deliver_policy: :all,
               max_deliver: 5,
               ack_wait: 30,
               backoff: [1, 5, 10])
      end
      let(:mock_info) { double('ConsumerInfo', config: mock_config) }

      before do
        allow(mock_jts).to receive(:consumer_info).and_return(mock_info)
      end

      it 'does not recreate the consumer' do
        expect(mock_jts).not_to receive(:delete_consumer)
        expect(mock_jts).not_to receive(:add_consumer)
        manager.ensure_consumer!
      end
    end

    context 'when consumer exists with different config' do
      let(:mock_config) do
        double('ConsumerConfig',
               filter_subject: 'dest_app.sync.test_app',
               ack_policy: :explicit,
               deliver_policy: :all,
               max_deliver: 3,
               ack_wait: 30,
               backoff: [1])
      end
      let(:mock_info) { double('ConsumerInfo', config: mock_config) }

      before do
        allow(mock_jts).to receive(:consumer_info).and_return(mock_info)
        allow(mock_jts).to receive(:delete_consumer)
        allow(mock_jts).to receive(:add_consumer)
      end

      it 'deletes the existing consumer' do
        expect(mock_jts).to receive(:delete_consumer).with(config.stream_name, durable)
        manager.ensure_consumer!
      end

      it 'creates a new consumer with desired config' do
        expect(mock_jts).to receive(:add_consumer).with(
          config.stream_name,
          hash_including(durable_name: durable, max_deliver: 5)
        )
        manager.ensure_consumer!
      end
    end

    context 'when delete fails during recreate' do
      let(:mock_config) do
        double('ConsumerConfig',
               filter_subject: 'dest_app.sync.test_app',
               ack_policy: :explicit,
               deliver_policy: :all,
               max_deliver: 3,
               ack_wait: 30,
               backoff: [1])
      end
      let(:mock_info) { double('ConsumerInfo', config: mock_config) }

      before do
        allow(mock_jts).to receive(:consumer_info).and_return(mock_info)
        allow(mock_jts).to receive(:delete_consumer).and_raise(NATS::JetStream::Error.new('not found'))
        allow(mock_jts).to receive(:add_consumer)
      end

      it 'logs warning but continues to create' do
        expect(mock_jts).to receive(:add_consumer)
        manager.ensure_consumer!
      end
    end
  end

  describe '#subscribe!' do
    before do
      allow(mock_jts).to receive(:pull_subscribe)
    end

    it 'creates a pull subscription' do
      expect(mock_jts).to receive(:pull_subscribe).with(
        manager.filter_subject,
        durable,
        hash_including(stream: manager.stream_name, config: manager.desired_consumer_cfg)
      )
      manager.subscribe!
    end

    context 'when JS API disabled' do
      before { config.disable_js_api = true }

      it 'binds to existing consumer without config' do
        expect(mock_jts).to receive(:pull_subscribe).with(
          manager.filter_subject,
          durable,
          hash_including(stream: manager.stream_name, bind: true)
        )
        manager.subscribe!
      end
    end
  end

  describe 'duration normalization' do
    let(:manager_instance) { described_class.new(mock_jts, durable, config) }

    describe '#duration_to_seconds' do
      it 'converts large integers as nanoseconds to seconds' do
        # 30 seconds in nanoseconds
        result = manager_instance.send(:duration_to_seconds, 30_000_000_000)
        expect(result).to eq(30)
      end

      it 'converts small integers using auto heuristic' do
        result = manager_instance.send(:duration_to_seconds, 30)
        expect(result).to eq(30)
      end

      it 'converts string durations' do
        result = manager_instance.send(:duration_to_seconds, '30s')
        expect(result).to eq(30)
      end

      it 'handles millisecond strings by rounding up' do
        result = manager_instance.send(:duration_to_seconds, '500ms')
        expect(result).to eq(1)
      end

      it 'returns nil for nil input' do
        result = manager_instance.send(:duration_to_seconds, nil)
        expect(result).to be_nil
      end

      it 'raises error for invalid input' do
        expect do
          manager_instance.send(:duration_to_seconds, Object.new)
        end.to raise_error(ArgumentError, /invalid duration/)
      end
    end

    describe 'config normalization' do
      it 'normalizes consumer config from server' do
        server_cfg = {
          filter_subject: 'test.subject',
          ack_policy: :explicit,
          deliver_policy: :all,
          max_deliver: 5,
          ack_wait: 30 * NATS::NANOSECONDS,
          backoff: [1, 5].map { |s| s * NATS::NANOSECONDS }
        }

        normalized = manager_instance.send(:normalize_consumer_config, server_cfg)

        expect(normalized).to eq(
          filter_subject: 'test.subject',
          ack_policy: 'explicit',
          deliver_policy: 'all',
          max_deliver: 5,
          ack_wait_nanos: 30 * NATS::NANOSECONDS,
          backoff_nanos: [1, 5].map { |s| s * NATS::NANOSECONDS }
        )
      end

      it 'handles symbol ack_policy conversion' do
        cfg = { ack_policy: :Explicit }
        normalized = manager_instance.send(:normalize_consumer_config, cfg)
        expect(normalized[:ack_policy]).to eq('explicit')
      end

      it 'normalizes nil values' do
        cfg = { filter_subject: nil, ack_policy: nil }
        normalized = manager_instance.send(:normalize_consumer_config, cfg)
        expect(normalized[:filter_subject]).to be_nil
        expect(normalized[:ack_policy]).to be_nil
      end

      it 'normalizes JetStream ConsumerInfo units (ack_wait/backoff) in nanos' do
        created_at = Time.now.iso8601
        consumer_info = NATS::JetStream::API::ConsumerInfo.new(
          type: 'pull',
          stream_name: config.stream_name,
          name: durable,
          created: created_at,
          config: {
            durable_name: durable,
            filter_subject: config.destination_subject,
            ack_policy: 'explicit',
            deliver_policy: 'all',
            max_deliver: 5,
            ack_wait: 30 * NATS::NANOSECONDS,
            backoff: [1, 5].map { |s| s * NATS::NANOSECONDS }
          },
          delivered: { consumer_seq: 0, stream_seq: 0, last_active: created_at },
          ack_floor: { consumer_seq: 0, stream_seq: 0, last_active: created_at },
          num_ack_pending: 0,
          num_redelivered: 0,
          num_waiting: 0,
          num_pending: 0,
          cluster: {},
          push_bound: false
        )

        normalized = manager_instance.send(:normalize_consumer_config, consumer_info.config)

        expect(normalized[:ack_wait_nanos]).to eq(30 * NATS::NANOSECONDS)
        expect(normalized[:backoff_nanos]).to eq([1, 5].map { |s| s * NATS::NANOSECONDS })
      end
    end
  end

  describe 'struct and hash access' do
    it 'retrieves value from hash' do
      hash = { filter_subject: 'test.value' }
      result = manager.send(:get, hash, :filter_subject)
      expect(result).to eq('test.value')
    end

    it 'retrieves value from struct-like object' do
      obj = double('Struct', filter_subject: 'test.value')
      result = manager.send(:get, obj, :filter_subject)
      expect(result).to eq('test.value')
    end
  end
end
