# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::MessageProcessor do
  let(:jts) { double('jetstream') }
  let(:handler) { double('handler', arity: 1) }
  let(:dlq) { instance_double(JetstreamBridge::DlqPublisher) }
  let(:backoff) { instance_double(JetstreamBridge::BackoffStrategy) }
  let(:processor) { described_class.new(jts, handler, dlq: dlq, backoff: backoff) }

  let(:metadata) do
    double('metadata', num_delivered: deliveries, sequence: 1, consumer: 'dur', stream: 'stream')
  end

  let(:msg) do
    double('msg',
           data: Oj.dump({
                           'event_type' => 'user.created',
                           'payload' => { 'foo' => 'bar' }
                         }),
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
      # Handler receives Event object (new style)
      expect(handler).to receive(:call) do |event|
        expect(event).to be_a(JetstreamBridge::Models::Event)
        expect(event.type).to eq('user.created')
      end
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

  describe 'middleware integration' do
    let(:deliveries) { 1 }
    let(:middleware) { double('middleware') }
    let(:middleware_chain) { JetstreamBridge::ConsumerMiddleware::MiddlewareChain.new }
    let(:processor_with_middleware) do
      described_class.new(jts, handler, dlq: dlq, backoff: backoff, middleware_chain: middleware_chain)
    end

    context 'with middleware chain' do
      it 'processes event through middleware chain' do
        middleware_chain.use(middleware)

        expect(middleware).to receive(:call) do |event, &block|
          expect(event).to be_a(JetstreamBridge::Models::Event)
          block.call(event)
        end

        expect(handler).to receive(:call) do |event|
          expect(event).to be_a(JetstreamBridge::Models::Event)
        end

        expect(msg).to receive(:ack)

        processor_with_middleware.handle_message(msg)
      end
    end

    context 'without middleware chain (nil)' do
      let(:processor_no_middleware) do
        proc = described_class.new(jts, handler, dlq: dlq, backoff: backoff, middleware_chain: nil)
        # Set @middleware_chain to nil explicitly
        proc.instance_variable_set(:@middleware_chain, nil)
        proc
      end

      it 'calls handler directly without middleware' do
        expect(handler).to receive(:call) do |event|
          expect(event).to be_a(JetstreamBridge::Models::Event)
        end

        expect(msg).to receive(:ack)

        processor_no_middleware.handle_message(msg)
      end
    end
  end

  describe '#safe_nak' do
    let(:deliveries) { 3 }

    context 'when ctx and error are present and msg supports nak_with_delay' do
      it 'calls nak_with_delay with backoff delay' do
        ctx = JetstreamBridge::MessageContext.build(msg)
        error = StandardError.new('test error')

        allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
        expect(backoff).to receive(:delay).with(ctx.deliveries, error).and_return(5)
        expect(msg).to receive(:nak_with_delay).with(5)

        processor.send(:safe_nak, msg, ctx, error)
      end
    end

    context 'when ctx is nil' do
      it 'calls regular nak' do
        expect(msg).to receive(:nak)
        expect(msg).not_to receive(:nak_with_delay)

        processor.send(:safe_nak, msg, nil, StandardError.new('error'))
      end
    end

    context 'when error is nil' do
      it 'calls regular nak' do
        ctx = JetstreamBridge::MessageContext.build(msg)

        expect(msg).to receive(:nak)
        expect(msg).not_to receive(:nak_with_delay)

        processor.send(:safe_nak, msg, ctx, nil)
      end
    end

    context 'when msg does not respond to nak_with_delay' do
      it 'calls regular nak' do
        ctx = JetstreamBridge::MessageContext.build(msg)
        error = StandardError.new('test error')

        allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(false)
        expect(msg).to receive(:nak)
        expect(msg).not_to receive(:nak_with_delay)

        processor.send(:safe_nak, msg, ctx, error)
      end
    end

    context 'when nak raises an error' do
      it 'logs error and does not crash' do
        ctx = JetstreamBridge::MessageContext.build(msg)

        allow(msg).to receive(:nak).and_raise(StandardError, 'nak error')

        expect(JetstreamBridge::Logging).to receive(:error).with(
          /Failed to NAK.*nak error/,
          tag: 'JetstreamBridge::Consumer'
        )

        expect { processor.send(:safe_nak, msg, ctx, nil) }.not_to raise_error
      end
    end

    context 'when nak_with_delay raises an error' do
      it 'logs error and does not crash' do
        ctx = JetstreamBridge::MessageContext.build(msg)
        error = StandardError.new('test error')

        allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
        allow(backoff).to receive(:delay).and_return(2)
        allow(msg).to receive(:nak_with_delay).and_raise(StandardError, 'nak_with_delay error')

        expect(JetstreamBridge::Logging).to receive(:error).with(
          /Failed to NAK.*nak_with_delay error/,
          tag: 'JetstreamBridge::Consumer'
        )

        expect { processor.send(:safe_nak, msg, ctx, error) }.not_to raise_error
      end
    end
  end

  describe '#build_event_object' do
    let(:deliveries) { 2 }

    it 'creates Event object with metadata from context' do
      ctx = JetstreamBridge::MessageContext.build(msg)
      event_hash = { 'event_type' => 'test.event', 'payload' => { 'data' => 'value' } }

      event = processor.send(:build_event_object, event_hash, ctx)

      expect(event).to be_a(JetstreamBridge::Models::Event)
      expect(event.type).to eq('test.event')
      expect(event.metadata.subject).to eq(ctx.subject)
      expect(event.metadata.deliveries).to eq(ctx.deliveries)
      expect(event.metadata.stream).to eq(ctx.stream)
      expect(event.metadata.sequence).to eq(ctx.seq)
      expect(event.metadata.consumer).to eq(ctx.consumer)
    end
  end

  describe 'error logging and backtrace' do
    let(:deliveries) { 1 }

    it 'handles and naks when handler crashes' do
      allow(handler).to receive(:call).and_raise(StandardError, 'handler crash')
      allow(msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
      expect(msg).to receive(:nak_with_delay)

      # Should not crash, should call safe_nak
      expect { processor.handle_message(msg) }.not_to raise_error
    end
  end

  describe 'MessageContext.build with edge cases' do
    context 'when header nats-msg-id is empty string' do
      let(:deliveries) { 1 }
      let(:msg_empty_id) do
        double('msg',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: { 'nats-msg-id' => '' },
               subject: 'test.subject',
               metadata: metadata)
      end

      it 'uses empty string from header' do
        ctx = JetstreamBridge::MessageContext.build(msg_empty_id)
        # MessageContext.build uses header['nats-msg-id'] || UUID
        # Empty string is truthy, so it uses empty string
        expect(ctx.event_id).to eq('')
      end
    end

    context 'when header is empty hash (no nats-msg-id key)' do
      let(:deliveries) { 1 }
      let(:msg_no_id_key) do
        double('msg',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: {},
               subject: 'test.subject',
               metadata: metadata)
      end

      it 'generates UUID when key is missing' do
        ctx = JetstreamBridge::MessageContext.build(msg_no_id_key)
        expect(ctx.event_id).to match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
      end
    end
  end

  describe 'DLQ delivery path coverage' do
    let(:deliveries) { 1 }

    context 'when parse_message returns nil after DLQ success' do
      let(:bad_msg) do
        double('msg',
               data: 'invalid json {',
               header: { 'nats-msg-id' => 'bad-json' },
               subject: 'test.subject',
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'returns early without calling process_event' do
        expect(dlq).to receive(:publish).and_return(true)
        expect(bad_msg).to receive(:ack)
        expect(handler).not_to receive(:call)

        processor.handle_message(bad_msg)
      end
    end

    context 'when parse_message returns nil after DLQ failure' do
      let(:bad_msg) do
        double('msg',
               data: 'invalid json {',
               header: { 'nats-msg-id' => 'bad-json' },
               subject: 'test.subject',
               metadata: metadata,
               nak: nil,
               nak_with_delay: nil)
      end

      it 'returns early without calling process_event' do
        allow(bad_msg).to receive(:respond_to?).with(:nak_with_delay).and_return(true)
        expect(dlq).to receive(:publish).and_return(false)
        expect(bad_msg).to receive(:nak_with_delay)
        expect(handler).not_to receive(:call)

        processor.handle_message(bad_msg)
      end
    end
  end
end
