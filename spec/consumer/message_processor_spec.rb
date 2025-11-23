# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::MessageProcessor do
  let(:jts) { double('jetstream') }
  let(:handler) { double('handler') }
  let(:dlq) { instance_double(JetstreamBridge::DlqPublisher) }
  let(:backoff) { instance_double(JetstreamBridge::BackoffStrategy) }
  let(:processor) { described_class.new(jts, handler, dlq: dlq, backoff: backoff) }

  let(:metadata) do
    double('metadata', num_delivered: deliveries, sequence: 1, consumer: 'dur', stream: 'stream')
  end

  let(:msg) do
    double('msg',
           data: Oj.dump({ foo: 'bar' }),
           header: { 'nats-msg-id' => 'abc-123' },
           subject: 'test.subject',
           metadata: metadata,
           ack: nil,
           nak: nil,
           nak_with_delay: nil)
  end

  before do
    JetstreamBridge.configure do |c|
      c.max_deliver = 5
    end
    allow(backoff).to receive(:delay).and_return(2)
  end

  after { JetstreamBridge.reset! }

  describe 'MessageContext.build' do
    context 'when message has header with nats-msg-id' do
      let(:deliveries) { 1 }

      it 'uses the nats-msg-id as event_id' do
        ctx = JetstreamBridge::MessageContext.build(msg)
        expect(ctx.event_id).to eq('abc-123')
      end
    end

    context 'when message has no header' do
      let(:deliveries) { 1 }
      let(:msg_no_header) do
        double('msg',
               data: Oj.dump({ foo: 'bar' }),
               header: nil,
               subject: 'test.subject',
               metadata: metadata)
      end

      it 'generates a UUID for event_id' do
        ctx = JetstreamBridge::MessageContext.build(msg_no_header)
        expect(ctx.event_id).to match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
      end
    end

    context 'when message metadata is nil' do
      let(:msg_no_metadata) do
        double('msg',
               data: Oj.dump({ foo: 'bar' }),
               header: { 'nats-msg-id' => 'test-id' },
               subject: 'test.subject',
               metadata: nil)
      end

      it 'handles nil metadata gracefully' do
        ctx = JetstreamBridge::MessageContext.build(msg_no_metadata)
        expect(ctx.deliveries).to eq(0)
        expect(ctx.seq).to be_nil
        expect(ctx.consumer).to be_nil
        expect(ctx.stream).to be_nil
      end
    end
  end

  describe 'BackoffStrategy' do
    let(:strategy) { JetstreamBridge::BackoffStrategy.new }

    context 'with transient errors' do
      it 'uses shorter base delay for Timeout::Error' do
        delay = strategy.delay(1, Timeout::Error.new)
        expect(delay).to eq(1) # 0.5 * 2^0 = 0.5, clamped to MIN_DELAY = 1
      end

      it 'uses shorter base delay for IOError' do
        delay = strategy.delay(2, IOError.new)
        expect(delay).to eq(1) # 0.5 * 2^1 = 1
      end
    end

    context 'with non-transient errors' do
      it 'uses longer base delay' do
        delay = strategy.delay(1, StandardError.new)
        expect(delay).to eq(2) # 2.0 * 2^0 = 2
      end

      it 'caps at MAX_DELAY' do
        delay = strategy.delay(10, StandardError.new)
        expect(delay).to eq(60) # Would be 128, clamped to 60
      end
    end

    it 'respects MIN_DELAY boundary' do
      delay = strategy.delay(0, Timeout::Error.new)
      expect(delay).to be >= 1
    end
  end

  context 'when handler succeeds' do
    let(:deliveries) { 1 }

    it 'acks the message' do
      expect(handler).to receive(:call).with(Oj.load(msg.data, mode: :strict), msg.subject, deliveries)
      expect(msg).to receive(:ack)
      expect(dlq).not_to receive(:publish)
      processor.handle_message(msg)
    end
  end

  context 'when JSON is malformed' do
    let(:deliveries) { 1 }
    let(:bad_msg) do
      double('msg',
             data: 'not valid json {',
             header: { 'nats-msg-id' => 'bad-json' },
             subject: 'test.subject',
             metadata: metadata,
             ack: nil,
             nak: nil,
             nak_with_delay: nil)
    end

    context 'when DLQ publish succeeds' do
      it 'acks the message and logs warning' do
        expect(dlq).to receive(:publish).and_return(true)
        expect(bad_msg).to receive(:ack)
        expect(bad_msg).not_to receive(:nak)
        processor.handle_message(bad_msg)
      end
    end

    context 'when DLQ publish fails' do
      it 'naks the message with backoff delay' do
        allow(bad_msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
        expect(dlq).to receive(:publish).and_return(false)
        expect(bad_msg).not_to receive(:ack)
        expect(backoff).to receive(:delay).with(deliveries, kind_of(Oj::ParseError)).and_return(2)
        expect(bad_msg).to receive(:nak_with_delay).with(2)
        processor.handle_message(bad_msg)
      end
    end
  end

  context 'when handler raises an unrecoverable error' do
    let(:deliveries) { 3 }

    context 'when DLQ publish succeeds' do
      it 'acks and publishes to the DLQ' do
        allow(handler).to receive(:call).and_raise(ArgumentError, 'bad')
        expect(dlq).to receive(:publish).and_return(true)
        expect(msg).to receive(:ack)
        processor.handle_message(msg)
      end
    end

    context 'when DLQ publish fails' do
      it 'naks the message with backoff delay' do
        allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
        allow(handler).to receive(:call).and_raise(TypeError, 'type error')
        expect(dlq).to receive(:publish).and_return(false)
        expect(msg).not_to receive(:ack)
        expect(backoff).to receive(:delay).with(deliveries, kind_of(TypeError)).and_return(2)
        expect(msg).to receive(:nak_with_delay).with(2)
        processor.handle_message(msg)
      end
    end
  end

  context 'when handler raises a standard error' do
    let(:deliveries) { 2 }

    it 'naks the message with backoff delay' do
      allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
      allow(handler).to receive(:call).and_raise(StandardError, 'boom')
      expect(backoff).to receive(:delay).with(deliveries, kind_of(StandardError)).and_return(2)
      expect(msg).to receive(:nak_with_delay).with(2)
      expect(dlq).not_to receive(:publish)
      processor.handle_message(msg)
    end

    context 'when deliveries exceed max_deliver' do
      let(:deliveries) { 5 }

      context 'when DLQ publish succeeds' do
        it 'acks and publishes to DLQ' do
          allow(handler).to receive(:call).and_raise(StandardError, 'boom')
          expect(dlq).to receive(:publish).and_return(true)
          expect(msg).to receive(:ack)
          expect(msg).not_to receive(:nak)
          processor.handle_message(msg)
        end
      end

      context 'when DLQ publish fails' do
        it 'naks the message with backoff delay' do
          allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
          allow(handler).to receive(:call).and_raise(StandardError, 'boom')
          expect(dlq).to receive(:publish).and_return(false)
          expect(msg).not_to receive(:ack)
          expect(backoff).to receive(:delay).with(deliveries, kind_of(StandardError)).and_return(2)
          expect(msg).to receive(:nak_with_delay).with(2)
          processor.handle_message(msg)
        end
      end
    end
  end

  context 'when message does not support nak_with_delay' do
    let(:deliveries) { 2 }

    it 'falls back to regular nak' do
      allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(false)
      allow(handler).to receive(:call).and_raise(StandardError, 'boom')
      expect(msg).to receive(:nak)
      expect(msg).not_to receive(:nak_with_delay)
      processor.handle_message(msg)
    end
  end

  context 'when NAK itself fails' do
    let(:deliveries) { 2 }

    it 'logs error and does not crash' do
      allow(handler).to receive(:call).and_raise(StandardError, 'boom')
      allow(msg).to receive(:nak).and_raise(NATS::IO::Error, 'nak failed')
      expect { processor.handle_message(msg) }.not_to raise_error
    end
  end

  context 'when parsing crashes in handle_message' do
    let(:deliveries) { 1 }

    it 'safely naks and logs error' do
      allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
      allow(JetstreamBridge::MessageContext).to receive(:build).and_raise(StandardError, 'context build failed')
      # When context build fails, we don't have a ctx object so backoff.delay isn't called with specific args
      expect(msg).to receive(:nak)
      processor.handle_message(msg)
    end
  end
end
