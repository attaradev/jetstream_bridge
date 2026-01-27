# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::PullSubscriptionBuilder do
  let(:mock_jts) do
    double('NATS::JetStream').tap do |jts|
      allow(jts).to receive(:instance_variable_get).with(:@prefix).and_return('$JS.API')
    end
  end
  let(:durable) { 'test-consumer' }
  let(:stream_name) { 'test-stream' }
  let(:filter_subject) { 'test.subject' }
  let(:builder) { described_class.new(mock_jts, durable, stream_name, filter_subject) }
  let(:mock_nc) do
    double('NATS::Client').tap do |nc|
      allow(nc).to receive(:new_inbox).and_return('_INBOX.test123')
      allow(nc).to receive(:subscribe).and_return(mock_subscription)
    end
  end
  let(:mock_subscription) { double('Subscription') }

  describe '#build' do
    before do
      allow(mock_subscription).to receive(:instance_variable_set)
      allow(mock_subscription).to receive(:instance_variable_get)
      allow(mock_subscription).to receive(:extend)
      allow(mock_subscription).to receive(:jsi=)
    end

    it 'creates a new inbox for message delivery' do
      expect(mock_nc).to receive(:new_inbox).and_return('_INBOX.test123')
      builder.build(mock_nc)
    end

    it 'subscribes to the delivery inbox' do
      expect(mock_nc).to receive(:subscribe).with('_INBOX.test123')
      builder.build(mock_nc)
    end

    it 'stores NATS client handle on subscription' do
      expect(mock_subscription).to receive(:instance_variable_set).with(:@_jsb_nc, mock_nc)
      builder.build(mock_nc)
    end

    it 'stores delivery subject on subscription' do
      expect(mock_subscription).to receive(:instance_variable_set).with(:@_jsb_deliver, '_INBOX.test123')
      builder.build(mock_nc)
    end

    it 'stores next subject on subscription' do
      expected_next = '$JS.API.CONSUMER.MSG.NEXT.test-stream.test-consumer'
      expect(mock_subscription).to receive(:instance_variable_set).with(:@_jsb_next_subject, expected_next)
      builder.build(mock_nc)
    end

    it 'uses custom prefix if available' do
      allow(mock_jts).to receive(:instance_variable_get).with(:@prefix).and_return('$JS.API.CUSTOM')
      expected_next = '$JS.API.CUSTOM.CONSUMER.MSG.NEXT.test-stream.test-consumer'
      expect(mock_subscription).to receive(:instance_variable_set).with(:@_jsb_next_subject, expected_next)
      builder.build(mock_nc)
    end

    it 'returns the subscription' do
      result = builder.build(mock_nc)
      expect(result).to eq(mock_subscription)
    end

    context 'when PullSubscription mixin is available' do
      let(:pull_subscription_mod) { Module.new }

      before do
        stub_const('NATS::JetStream::PullSubscription', pull_subscription_mod)
      end

      it 'extends subscription with PullSubscription module' do
        expect(mock_subscription).to receive(:extend).with(pull_subscription_mod)
        builder.build(mock_nc)
      end

      it 'does not shim fetch' do
        expect(mock_subscription).not_to receive(:define_singleton_method)
        builder.build(mock_nc)
      end
    end

    context 'when PullSubscription mixin is not available' do
      before do
        hide_const('NATS::JetStream::PullSubscription')
      end

      it 'shims fetch method' do
        expect(mock_subscription).to receive(:define_singleton_method).with(:fetch)
        builder.build(mock_nc)
      end
    end

    context 'when NATS::JetStream::JS::Sub is available' do
      let(:js_sub_class) do
        Struct.new(:js, :stream, :consumer, :nms, keyword_init: true)
      end

      before do
        nats_jetstream = Module.new
        js_module = Module.new
        stub_const('NATS::JetStream', nats_jetstream)
        stub_const('NATS::JetStream::JS', js_module)
        stub_const('NATS::JetStream::JS::Sub', js_sub_class)
      end

      it 'attaches JSI using the official class' do
        allow(mock_subscription).to receive(:instance_variable_get).with(:@_jsb_next_subject)
                                                                   .and_return('$JS.API.CONSUMER.MSG.NEXT.test-stream.test-consumer')

        expect(mock_subscription).to receive(:jsi=) do |jsi|
          expect(jsi).to be_a(js_sub_class)
          expect(jsi.js).to eq(mock_jts)
          expect(jsi.stream).to eq(stream_name)
          expect(jsi.consumer).to eq(durable)
          expect(jsi.nms).to eq('$JS.API.CONSUMER.MSG.NEXT.test-stream.test-consumer')
        end

        builder.build(mock_nc)
      end
    end

    context 'when NATS::JetStream::JS::Sub is not available' do
      before do
        hide_const('NATS::JetStream')
      end

      it 'attaches JSI using fallback struct' do
        allow(mock_subscription).to receive(:instance_variable_get).with(:@_jsb_next_subject)
                                                                   .and_return('$JS.API.CONSUMER.MSG.NEXT.test-stream.test-consumer')

        expect(mock_subscription).to receive(:jsi=) do |jsi|
          expect(jsi.js).to eq(mock_jts)
          expect(jsi.stream).to eq(stream_name)
          expect(jsi.consumer).to eq(durable)
          expect(jsi.nms).to eq('$JS.API.CONSUMER.MSG.NEXT.test-stream.test-consumer')
        end

        builder.build(mock_nc)
      end
    end
  end

  describe 'fetch shim behavior' do
    # Use a real object that can have instance variables and methods defined
    let(:shimmed_sub) do
      obj = Object.new
      # Define minimal stub
      def obj.jsi=(val); end
      obj
    end

    before do
      hide_const('NATS::JetStream::PullSubscription')

      allow(mock_nc).to receive(:new_inbox).and_return('_INBOX.test')
      allow(mock_nc).to receive(:subscribe).and_return(shimmed_sub)
    end

    it 'implements fetch that publishes to next subject' do
      shimmed_nc = double('NATS::Client')

      builder.build(mock_nc)

      # Set instance variables after build (simulating what build does)
      shimmed_sub.instance_variable_set(:@_jsb_nc, shimmed_nc)
      shimmed_sub.instance_variable_set(:@_jsb_deliver, '_INBOX.deliver')
      shimmed_sub.instance_variable_set(:@_jsb_next_subject, 'next.subject')

      expect(shimmed_nc).to receive(:publish) do |subject, payload, reply|
        expect(subject).to eq('next.subject')
        expect(payload).to include('"batch":10')
        expect(payload).to include('"expires"')
        expect(reply).to eq('_INBOX.deliver')
      end
      expect(shimmed_nc).to receive(:flush)

      allow(shimmed_sub).to receive(:next_msg).and_raise(NATS::IO::Timeout)

      shimmed_sub.fetch(10, timeout: 5)
    end

    it 'raises error when NATS handles are missing' do
      builder.build(mock_nc)

      # Clear the instance variables to simulate missing handles
      shimmed_sub.instance_variable_set(:@_jsb_nc, nil)

      expect { shimmed_sub.fetch(10) }.to raise_error(
        JetstreamBridge::ConnectionError,
        'Missing NATS handles for fetch'
      )
    end

    it 'collects messages up to batch size' do
      shimmed_nc = double('NATS::Client')

      builder.build(mock_nc)

      # Set instance variables after build
      shimmed_sub.instance_variable_set(:@_jsb_nc, shimmed_nc)
      shimmed_sub.instance_variable_set(:@_jsb_deliver, '_INBOX.deliver')
      shimmed_sub.instance_variable_set(:@_jsb_next_subject, 'next.subject')

      allow(shimmed_nc).to receive(:publish)
      allow(shimmed_nc).to receive(:flush)

      msg1 = double('Message1')
      msg2 = double('Message2')

      call_count = 0
      allow(shimmed_sub).to receive(:next_msg) do
        call_count += 1
        case call_count
        when 1 then msg1
        when 2 then msg2
        else raise NATS::IO::Timeout
        end
      end

      result = shimmed_sub.fetch(5, timeout: 1)
      expect(result).to eq([msg1, msg2])
    end

    it 'handles NATS::Timeout gracefully' do
      shimmed_nc = double('NATS::Client')

      builder.build(mock_nc)

      # Set instance variables after build
      shimmed_sub.instance_variable_set(:@_jsb_nc, shimmed_nc)
      shimmed_sub.instance_variable_set(:@_jsb_deliver, '_INBOX.deliver')
      shimmed_sub.instance_variable_set(:@_jsb_next_subject, 'next.subject')

      allow(shimmed_nc).to receive(:publish)
      allow(shimmed_nc).to receive(:flush)
      allow(shimmed_sub).to receive(:next_msg).and_raise(NATS::Timeout)

      result = shimmed_sub.fetch(3, timeout: 1)
      expect(result).to eq([])
    end
  end
end
