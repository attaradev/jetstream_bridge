# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::SubscriptionManager do
  let(:mock_jts) { double('NATS::JetStream') }
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.destination_app = 'dest_app'
      c.app_name = 'test_app'
      c.stream_name = 'jetstream-bridge-stream'
      c.max_deliver = 5
      c.ack_wait = 30
      c.backoff = [1, 5, 10]
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
      expect(manager.stream_name).to eq('jetstream-bridge-stream')
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

    it 'converts ack_wait to seconds' do
      expect(manager.desired_consumer_cfg[:ack_wait]).to eq(30)
    end

    it 'converts backoff array to seconds' do
      expect(manager.desired_consumer_cfg[:backoff]).to eq([1, 5, 10])
    end
  end

  describe '#ensure_consumer!' do
    context 'when forced (provisioning)' do
      before { allow(mock_jts).to receive(:add_consumer) }

      it 'creates the consumer without verifying' do
        expect(mock_jts).to receive(:add_consumer).with(
          config.stream_name,
          hash_including(durable_name: durable)
        )
        manager.ensure_consumer!(force: true)
      end
    end

    context 'when auto_provision is enabled' do
      before { allow(mock_jts).to receive(:add_consumer) }

      it 'creates the consumer' do
        manager.ensure_consumer!
        expect(mock_jts).to have_received(:add_consumer).with(
          config.stream_name,
          hash_including(durable_name: durable)
        )
      end
    end

    context 'when auto_provision is disabled' do
      before do
        allow(config).to receive(:auto_provision).and_return(false)
        allow(mock_jts).to receive(:add_consumer)
      end

      it 'skips provisioning' do
        manager.ensure_consumer!
        expect(mock_jts).not_to have_received(:add_consumer)
      end
    end
  end

  describe '#subscribe!' do
    context 'with pull consumer (default)' do
      it 'uses verification-free subscription path' do
        expect(manager).to receive(:subscribe_without_verification!)
        manager.subscribe!
      end
    end

    context 'with push consumer' do
      before do
        allow(config).to receive(:push_consumer?).and_return(true)
        allow(config).to receive(:push_delivery_subject).and_return('dest_app.sync.test_app.worker')
      end

      it 'uses push subscription path' do
        expect(manager).to receive(:subscribe_push!)
        manager.subscribe!
      end
    end
  end

  describe '#subscribe_push!' do
    let(:mock_nc) { double('NATS::Client') }
    let(:mock_subscription) { double('Subscription') }

    before do
      allow(config).to receive(:push_consumer?).and_return(true)
      allow(config).to receive(:push_delivery_subject).and_return('dest_app.sync.test_app.worker')
      allow(manager).to receive(:resolve_nc).and_return(mock_nc)
    end

    context 'when NATS client is available' do
      it 'subscribes to the delivery subject' do
        allow(mock_nc).to receive(:respond_to?).with(:subscribe).and_return(true)
        expect(mock_nc).to receive(:subscribe).with('dest_app.sync.test_app.worker').and_return(mock_subscription)
        manager.send(:subscribe_push!)
      end

      it 'returns the subscription' do
        allow(mock_nc).to receive(:respond_to?).with(:subscribe).and_return(true)
        allow(mock_nc).to receive(:subscribe).and_return(mock_subscription)
        result = manager.send(:subscribe_push!)
        expect(result).to eq(mock_subscription)
      end
    end

    context 'when NATS client is not available but JetStream has subscribe' do
      before do
        allow(manager).to receive(:resolve_nc).and_return(nil)
        allow(mock_jts).to receive(:respond_to?).with(:subscribe).and_return(true)
      end

      it 'uses JetStream subscribe fallback' do
        expect(mock_jts).to receive(:subscribe).with('dest_app.sync.test_app.worker').and_return(mock_subscription)
        manager.send(:subscribe_push!)
      end
    end

    context 'when no client is available' do
      before do
        allow(manager).to receive(:resolve_nc).and_return(nil)
        allow(mock_jts).to receive(:respond_to?).with(:subscribe).and_return(false)
      end

      it 'raises ConnectionError' do
        expect do
          manager.send(:subscribe_push!)
        end.to raise_error(JetstreamBridge::ConnectionError, /Unable to create push subscription/)
      end
    end
  end

  describe 'push consumer config' do
    before do
      allow(config).to receive(:push_consumer?).and_return(true)
      allow(config).to receive(:push_delivery_subject).and_return('dest_app.sync.test_app.worker')
    end

    it 'includes deliver_subject in consumer config' do
      manager_with_push = described_class.new(mock_jts, durable, config)
      expect(manager_with_push.desired_consumer_cfg[:deliver_subject]).to eq('dest_app.sync.test_app.worker')
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

      it 'converts Float using auto heuristic' do
        result = manager_instance.send(:duration_to_seconds, 30.5)
        expect(result).to eq(31) # rounds up from 30.5
      end

      it 'converts object with to_f method' do
        obj_with_to_f = Struct.new(:value) do
          def to_f
            15.0
          end
        end.new(15)

        result = manager_instance.send(:duration_to_seconds, obj_with_to_f)
        expect(result).to eq(15)
      end
    end

    # config normalization no longer used (verification removed)
  end

  describe '#resolve_nc' do
    let(:manager_instance) { described_class.new(mock_jts, durable, config) }
    let(:mock_nc) { double('NATS::Client') }

    it 'returns @jts.nc when available' do
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(true)
      allow(mock_jts).to receive(:nc).and_return(mock_nc)
      result = manager_instance.send(:resolve_nc)
      expect(result).to eq(mock_nc)
    end

    it 'uses instance_variable_get fallback when nc method not available' do
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:instance_variable_defined?).with(:@nc).and_return(true)
      allow(mock_jts).to receive(:instance_variable_get).with(:@nc).and_return(mock_nc)
      result = manager_instance.send(:resolve_nc)
      expect(result).to eq(mock_nc)
    end

    it 'returns mock_nats_client from config when available' do
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:instance_variable_defined?).with(:@nc).and_return(false)
      allow(config).to receive(:respond_to?).with(:mock_nats_client).and_return(true)
      allow(config).to receive(:mock_nats_client).and_return(mock_nc)
      result = manager_instance.send(:resolve_nc)
      expect(result).to eq(mock_nc)
    end

    it 'returns nil when no client available' do
      allow(mock_jts).to receive(:respond_to?).with(:nc).and_return(false)
      allow(mock_jts).to receive(:instance_variable_defined?).with(:@nc).and_return(false)
      allow(config).to receive(:respond_to?).with(:mock_nats_client).and_return(false)
      result = manager_instance.send(:resolve_nc)
      expect(result).to be_nil
    end
  end

  describe '#build_pull_subscription' do
    let(:manager_instance) { described_class.new(mock_jts, durable, config) }
    let(:mock_nc) { double('NATS::Client') }
    let(:mock_builder) { instance_double(JetstreamBridge::PullSubscriptionBuilder) }
    let(:mock_subscription) { double('Subscription') }

    it 'creates subscription using PullSubscriptionBuilder' do
      expect(JetstreamBridge::PullSubscriptionBuilder).to receive(:new)
        .with(mock_jts, durable, config.stream_name, 'dest_app.sync.test_app')
        .and_return(mock_builder)
      expect(mock_builder).to receive(:build).with(mock_nc).and_return(mock_subscription)

      result = manager_instance.send(:build_pull_subscription, mock_nc)
      expect(result).to eq(mock_subscription)
    end
  end

  describe '#subscribe_without_verification! edge cases' do
    let(:manager_instance) { described_class.new(mock_jts, durable, config) }
    let(:mock_nc) { double('NATS::Client') }

    context 'when nc lacks required methods but jts has pull_subscribe' do
      it 'uses pull_subscribe fallback' do
        allow(manager_instance).to receive(:resolve_nc).and_return(mock_nc)
        allow(mock_nc).to receive(:respond_to?).with(:new_inbox).and_return(false)
        allow(mock_jts).to receive(:respond_to?).with(:pull_subscribe).and_return(true)
        expect(mock_jts).to receive(:pull_subscribe)
          .with('dest_app.sync.test_app', durable, stream: config.stream_name)

        manager_instance.send(:subscribe_without_verification!)
      end
    end

    context 'when no path available' do
      it 'raises ConnectionError' do
        allow(manager_instance).to receive(:resolve_nc).and_return(nil)
        allow(mock_jts).to receive(:respond_to?).with(:pull_subscribe).and_return(false)

        expect do
          manager_instance.send(:subscribe_without_verification!)
        end.to raise_error(JetstreamBridge::ConnectionError, /Unable to create subscription/)
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
