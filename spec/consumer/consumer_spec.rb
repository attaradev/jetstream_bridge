# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge::Consumer do
  let(:jts) { double('jetstream') }
  let(:subscription) { double('subscription') }
  let(:sub_mgr) { instance_double(JetstreamBridge::SubscriptionManager) }
  let(:processor) { instance_double(JetstreamBridge::MessageProcessor) }

  before do
    JetstreamBridge.reset!
    # Mock Connection methods to return jetstream context
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
    allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(jts)
    JetstreamBridge.configure { |c| c.destination_app = 'dest' }
    # Manually mark as initialized so Consumer can be created
    JetstreamBridge.instance_variable_set(:@connection_initialized, true)
    allow(JetstreamBridge::SubscriptionManager).to receive(:new).and_return(sub_mgr)
    allow(JetstreamBridge::MessageProcessor).to receive(:new).and_return(processor)
    allow(sub_mgr).to receive(:ensure_consumer!)
    allow(sub_mgr).to receive(:subscribe!).and_return(subscription)
    allow(processor).to receive(:handle_message)
  end

  after { JetstreamBridge.reset! }

  describe 'initialization' do
    it 'ensures and subscribes the consumer with block' do
      described_class.new { |*| nil }
      expect(JetstreamBridge::SubscriptionManager)
        .to have_received(:new)
        .with(jts, JetstreamBridge.config.durable_name, JetstreamBridge.config)
      expect(sub_mgr).to have_received(:ensure_consumer!)
      expect(sub_mgr).to have_received(:subscribe!)
    end

    it 'accepts handler as first argument' do
      handler = -> {}
      consumer = described_class.new(handler)
      expect(consumer).to be_a(described_class)
    end

    it 'raises error when neither handler nor block provided' do
      expect do
        described_class.new
      end.to raise_error(ArgumentError, /handler or block required/)
    end

    it 'accepts custom durable_name and batch_size' do
      consumer = described_class.new(durable_name: 'custom-durable', batch_size: 50) { |*| nil }
      expect(consumer.durable).to eq('custom-durable')
      expect(consumer.batch_size).to eq(50)
    end
  end

  describe '#process_batch' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'processes fetched messages' do
      msg1 = double('msg1')
      msg2 = double('msg2')
      allow(subscription).to receive(:fetch).and_return([msg1, msg2])

      expect(processor).to receive(:handle_message).with(msg1).ordered
      expect(processor).to receive(:handle_message).with(msg2).ordered

      expect(consumer.send(:process_batch)).to eq(2)
    end

    it 'returns 0 when no messages are fetched' do
      allow(subscription).to receive(:fetch).and_return([])
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'returns 0 when fetch returns nil' do
      allow(subscription).to receive(:fetch).and_return(nil)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'handles NATS::Timeout gracefully' do
      allow(subscription).to receive(:fetch).and_raise(NATS::Timeout)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'handles NATS::IO::Timeout gracefully' do
      allow(subscription).to receive(:fetch).and_raise(NATS::IO::Timeout)
      expect(consumer.send(:process_batch)).to eq(0)
    end

    it 'recovers subscription on recoverable JetStream error' do
      err = NATS::JetStream::Error.new('consumer not found')
      allow(subscription).to receive(:fetch).and_raise(err)

      expect(consumer.send(:process_batch)).to eq(0)
      expect(sub_mgr).to have_received(:ensure_consumer!).twice
      expect(sub_mgr).to have_received(:subscribe!).twice
    end

    it 'handles non-recoverable JetStream errors' do
      err = NATS::JetStream::Error.new('some other error')
      allow(subscription).to receive(:fetch).and_raise(err)

      expect(consumer.send(:process_batch)).to eq(0)
      # Should not attempt recovery for non-recoverable errors
      expect(sub_mgr).to have_received(:ensure_consumer!).once
    end

    it 'handles StandardError in process_batch' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'unexpected error')
      expect(consumer.send(:process_batch)).to eq(0)
    end
  end

  describe '#fetch_messages' do
    subject(:consumer) { described_class.new { |*| nil } }

    context 'with pull consumer (default)' do
      before do
        allow(JetstreamBridge.config).to receive(:push_consumer?).and_return(false)
      end

      it 'delegates to fetch_messages_pull' do
        expect(subscription).to receive(:fetch).with(25, timeout: 5).and_return([])
        consumer.send(:fetch_messages)
      end
    end

    context 'with push consumer' do
      before do
        allow(JetstreamBridge.config).to receive(:push_consumer?).and_return(true)
      end

      it 'delegates to fetch_messages_push' do
        expect(consumer).to receive(:fetch_messages_push).and_return([])
        consumer.send(:fetch_messages)
      end
    end
  end

  describe '#fetch_messages_pull' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'calls fetch on subscription with batch size and timeout' do
      expect(subscription).to receive(:fetch).with(25, timeout: 5).and_return([])
      consumer.send(:fetch_messages_pull)
    end

    it 'returns messages from fetch' do
      msg = double('message')
      allow(subscription).to receive(:fetch).and_return([msg])
      result = consumer.send(:fetch_messages_pull)
      expect(result).to eq([msg])
    end
  end

  describe '#fetch_messages_push' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'collects messages using next_msg' do
      msg1 = double('msg1')
      msg2 = double('msg2')

      call_count = 0
      allow(subscription).to receive(:next_msg) do |timeout:|
        expect(timeout).to eq(5)
        call_count += 1
        case call_count
        when 1 then msg1
        when 2 then msg2
        else raise NATS::Timeout
        end
      end

      result = consumer.send(:fetch_messages_push)
      expect(result).to eq([msg1, msg2])
    end

    it 'stops collecting on NATS::Timeout' do
      msg1 = double('msg1')
      call_count = 0
      allow(subscription).to receive(:next_msg) do |timeout:|
        expect(timeout).to eq(5)
        call_count += 1
        call_count == 1 ? msg1 : raise(NATS::Timeout)
      end

      result = consumer.send(:fetch_messages_push)
      expect(result).to eq([msg1])
    end

    it 'stops collecting on NATS::IO::Timeout' do
      msg1 = double('msg1')
      call_count = 0
      allow(subscription).to receive(:next_msg) do |timeout:|
        expect(timeout).to eq(5)
        call_count += 1
        call_count == 1 ? msg1 : raise(NATS::IO::Timeout)
      end

      result = consumer.send(:fetch_messages_push)
      expect(result).to eq([msg1])
    end

    it 'returns empty array when first message times out' do
      allow(subscription).to receive(:next_msg).with(timeout: 5).and_raise(NATS::Timeout)

      result = consumer.send(:fetch_messages_push)
      expect(result).to eq([])
    end

    it 'collects up to batch_size messages' do
      messages = Array.new(25) { |i| double("msg#{i}") }
      call_count = 0
      allow(subscription).to receive(:next_msg) do |timeout:|
        expect(timeout).to eq(5)
        msg = messages[call_count]
        call_count += 1
        msg
      end

      result = consumer.send(:fetch_messages_push)
      expect(result.size).to eq(25)
    end

    it 'skips nil messages' do
      msg1 = double('msg1')
      msg2 = double('msg2')

      call_count = 0
      allow(subscription).to receive(:next_msg) do |timeout:|
        expect(timeout).to eq(5)
        call_count += 1
        case call_count
        when 1 then msg1
        when 2 then nil
        when 3 then msg2
        else raise NATS::Timeout
        end
      end

      result = consumer.send(:fetch_messages_push)
      expect(result).to eq([msg1, msg2])
    end
  end

  describe '#process_one' do
    subject(:consumer) { described_class.new { |*| nil } }

    let(:msg) { double('msg') }

    it 'processes message through handler' do
      expect(processor).to receive(:handle_message).with(msg)
      expect(consumer.send(:process_one, msg)).to eq(1)
    end

    it 'handles errors in message processing' do
      allow(processor).to receive(:handle_message).and_raise(StandardError, 'boom')
      expect(consumer.send(:process_one, msg)).to eq(0)
    end
  end

  describe '#stop!' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'sets shutdown_requested and running flags' do
      consumer.stop!
      expect(consumer.instance_variable_get(:@shutdown_requested)).to be true
      expect(consumer.instance_variable_get(:@running)).to be false
    end
  end

  describe 'with inbox enabled' do
    before do
      JetstreamBridge.configure { |c| c.use_inbox = true }
    end

    it 'initializes inbox processor' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      expect(consumer.instance_variable_get(:@inbox_proc)).to eq(inbox_proc)
    end

    it 'processes messages through inbox processor' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      msg = double('msg')

      expect(inbox_proc).to receive(:process).with(msg).and_return(true)
      expect(consumer.send(:process_one, msg)).to eq(1)
    end

    it 'returns 0 when inbox processor returns false' do
      inbox_proc = instance_double(JetstreamBridge::InboxProcessor)
      allow(JetstreamBridge::InboxProcessor).to receive(:new).and_return(inbox_proc)

      consumer = described_class.new { |*| nil }
      msg = double('msg')

      expect(inbox_proc).to receive(:process).with(msg).and_return(false)
      expect(consumer.send(:process_one, msg)).to eq(0)
    end
  end

  describe '#recoverable_consumer_error?' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'recognizes consumer not found error' do
      error = NATS::JetStream::Error.new('consumer not found')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes consumer deleted error' do
      error = NATS::JetStream::Error.new('consumer was deleted')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes no responders error' do
      error = NATS::JetStream::Error.new('no responders available')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes stream not found error' do
      error = NATS::JetStream::Error.new('stream not found')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'recognizes 404 error code' do
      error = NATS::JetStream::Error.new('err_code=404')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_truthy
    end

    it 'does not consider other errors as recoverable' do
      error = NATS::JetStream::Error.new('some other error')
      expect(consumer.send(:recoverable_consumer_error?, error)).to be_falsey
    end
  end

  describe '#idle_sleep' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'increases backoff when no messages processed' do
      initial_backoff = consumer.instance_variable_get(:@idle_backoff)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 0)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to be > initial_backoff
    end

    it 'resets backoff when messages are processed' do
      consumer.instance_variable_set(:@idle_backoff, 0.5)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 5)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to eq(described_class::IDLE_SLEEP_SECS)
    end

    it 'caps backoff at MAX_IDLE_BACKOFF_SECS' do
      consumer.instance_variable_set(:@idle_backoff, 2.0)
      allow(consumer).to receive(:sleep)

      consumer.send(:idle_sleep, 0)
      new_backoff = consumer.instance_variable_get(:@idle_backoff)

      expect(new_backoff).to be <= described_class::MAX_IDLE_BACKOFF_SECS
    end
  end

  describe '#drain_inflight_messages' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'processes pending messages during drain' do
      msg = double('msg')
      allow(subscription).to receive(:fetch).and_return([msg], [])
      allow(processor).to receive(:handle_message)

      consumer.send(:drain_inflight_messages)
      expect(processor).to have_received(:handle_message).with(msg)
    end

    it 'stops on timeout during drain' do
      allow(subscription).to receive(:fetch).and_raise(NATS::Timeout)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'stops on NATS::IO::Timeout during drain' do
      allow(subscription).to receive(:fetch).and_raise(NATS::IO::Timeout)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'handles errors during drain gracefully' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'drain error')
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'returns early if @psub is nil' do
      consumer.instance_variable_set(:@psub, nil)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end
  end

  describe 'initialization with missing destination_app' do
    before do
      JetstreamBridge.configure { |c| c.destination_app = nil }
    end

    it 'raises MissingConfigurationError' do
      expect do
        described_class.new { |*| nil }
      end.to raise_error(JetstreamBridge::MissingConfigurationError, /destination_app cannot be empty/)
    end
  end

  describe '#use (middleware)' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'adds middleware to the chain' do
      middleware = double('middleware')
      expect(consumer.middleware_chain).to receive(:use).with(middleware)
      consumer.use(middleware)
    end

    it 'returns self for method chaining' do
      middleware = double('middleware')
      allow(consumer.middleware_chain).to receive(:use)
      expect(consumer.use(middleware)).to eq(consumer)
    end

    it 'allows multiple middleware to be chained' do
      middleware1 = double('middleware1')
      middleware2 = double('middleware2')
      allow(consumer.middleware_chain).to receive(:use)

      result = consumer.use(middleware1).use(middleware2)
      expect(result).to eq(consumer)
    end
  end

  describe '#run!' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'loops while running is true' do
      allow(subscription).to receive(:fetch).and_return([])
      allow(consumer).to receive(:sleep)

      # Stop after first iteration
      call_count = 0
      allow(consumer).to receive(:process_batch) do
        call_count += 1
        consumer.stop! if call_count >= 2
        0
      end

      consumer.run!
      expect(call_count).to eq(2)
    end

    it 'calls drain_inflight_messages when shutdown is requested' do
      allow(subscription).to receive(:fetch).and_return([])
      allow(consumer).to receive(:sleep)

      # Stop immediately
      consumer.instance_variable_set(:@running, false)
      consumer.instance_variable_set(:@shutdown_requested, true)

      expect(consumer).to receive(:drain_inflight_messages)
      consumer.run!
    end

    it 'does not drain when shutdown not requested' do
      allow(subscription).to receive(:fetch).and_return([])
      allow(consumer).to receive(:sleep)

      # Stop without shutdown request
      consumer.instance_variable_set(:@running, false)
      consumer.instance_variable_set(:@shutdown_requested, false)

      expect(consumer).not_to receive(:drain_inflight_messages)
      consumer.run!
    end

    it 'processes batches and sleeps when idle' do
      allow(subscription).to receive(:fetch).and_return([])

      sleep_called = false
      allow(consumer).to receive(:sleep) do
        sleep_called = true
        consumer.stop! # Stop after first sleep
      end

      consumer.run!
      expect(sleep_called).to be true
    end
  end

  describe '#setup_signal_handlers' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'traps INT and TERM signals' do
      # Allow Signal.trap to be called (it will be called twice - once for each signal)
      allow(Signal).to receive(:trap).and_call_original
      expect { consumer.send(:setup_signal_handlers) }.not_to raise_error
    end

    it 'calls stop! when INT signal is received' do
      # Capture the signal handler block
      handler_block = nil
      allow(Signal).to receive(:trap) do |sig, &block|
        handler_block = block if sig == 'INT'
      end

      consumer.send(:setup_signal_handlers)

      # Execute the handler to simulate receiving INT signal
      expect(consumer).to receive(:stop!)
      handler_block&.call
    end

    it 'calls stop! when TERM signal is received' do
      # Capture the signal handler block
      handler_block = nil
      allow(Signal).to receive(:trap) do |sig, &block|
        handler_block = block if sig == 'TERM'
      end

      consumer.send(:setup_signal_handlers)

      # Execute the handler to simulate receiving TERM signal
      expect(consumer).to receive(:stop!)
      handler_block&.call
    end

    it 'handles ArgumentError when signal handlers unavailable' do
      allow(Signal).to receive(:trap).and_raise(ArgumentError, 'unavailable')
      expect { consumer.send(:setup_signal_handlers) }.not_to raise_error
    end
  end

  describe '#js_err_code' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'extracts error code from message' do
      message = 'some error err_code=503 occurred'
      expect(consumer.send(:js_err_code, message)).to eq(503)
    end

    it 'returns nil when no error code present' do
      message = 'some error without code'
      expect(consumer.send(:js_err_code, message)).to be_nil
    end

    it 'extracts 5-digit error codes' do
      message = 'error with err_code=10503'
      expect(consumer.send(:js_err_code, message)).to eq(10_503)
    end
  end

  describe '#handle_js_error' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'attempts recovery for recoverable errors' do
      error = NATS::JetStream::Error.new('consumer not found')
      expect(consumer).to receive(:recoverable_consumer_error?).with(error).and_return(true)
      expect(sub_mgr).to receive(:ensure_consumer!)
      expect(sub_mgr).to receive(:subscribe!).and_return(subscription)

      result = consumer.send(:handle_js_error, error)
      expect(result).to eq(0)
    end

    it 'does not attempt recovery for non-recoverable errors' do
      error = NATS::JetStream::Error.new('permission denied')
      expect(consumer).to receive(:recoverable_consumer_error?).with(error).and_return(false)

      result = consumer.send(:handle_js_error, error)
      expect(result).to eq(0)
    end
  end

  describe 'integration: full message processing flow' do
    subject(:consumer) { described_class.new { |event| processed_events << event.to_h } }

    let(:processed_events) { [] }
    let(:msg1) { double('msg1', data: '{"type":"test","payload":{"id":1}}') }
    let(:msg2) { double('msg2', data: '{"type":"test","payload":{"id":2}}') }

    before do
      allow(subscription).to receive(:fetch).and_return([msg1, msg2], [])
      allow(msg1).to receive(:ack)
      allow(msg2).to receive(:ack)
      allow(msg1).to receive(:subject).and_return('events.dest.test')
      allow(msg2).to receive(:subject).and_return('events.dest.test')
      allow(msg1).to receive(:metadata).and_return(double(num_delivered: 1))
      allow(msg2).to receive(:metadata).and_return(double(num_delivered: 1))
    end

    it 'processes multiple batches until stopped' do
      call_count = 0
      allow(subscription).to receive(:fetch) do
        call_count += 1
        if call_count == 1
          [msg1, msg2]
        else
          consumer.stop!
          []
        end
      end

      allow(consumer).to receive(:sleep)
      consumer.run!

      expect(call_count).to be >= 1
    end
  end

  describe 'error recovery scenarios' do
    subject(:consumer) { described_class.new { |*| nil } }

    context 'when multiple recoverable errors occur' do
      it 'continues processing after each recovery' do
        double('msg')
        errors = [
          NATS::JetStream::Error.new('consumer not found'),
          nil,  # successful fetch
          NATS::JetStream::Error.new('stream not found'),
          nil   # successful fetch
        ]
        error_index = 0

        allow(subscription).to receive(:fetch) do
          error = errors[error_index]
          error_index += 1
          raise error if error

          consumer.stop! if error_index >= errors.size
          []
        end

        allow(consumer).to receive(:sleep)
        consumer.run!

        # Should have attempted recovery twice (once for initialization)
        expect(sub_mgr).to have_received(:ensure_consumer!).at_least(3).times
      end
    end

    context 'when process_one raises error during batch' do
      it 'continues processing remaining messages' do
        msg1 = double('msg1')
        msg2 = double('msg2')
        msg3 = double('msg3')

        allow(subscription).to receive(:fetch).and_return([msg1, msg2, msg3], [])
        allow(processor).to receive(:handle_message).with(msg1)
        allow(processor).to receive(:handle_message).with(msg2).and_raise(StandardError, 'processing failed')
        allow(processor).to receive(:handle_message).with(msg3)

        result = consumer.send(:process_batch)

        # Should process 2 messages (msg1 and msg3), msg2 fails
        expect(result).to eq(2)
      end
    end
  end

  describe 'drain with multiple message batches' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'drains up to 5 batches of messages' do
      msg = double('msg')
      fetch_count = 0

      allow(subscription).to receive(:fetch) do
        fetch_count += 1
        fetch_count <= 5 ? [msg] : []
      end

      allow(processor).to receive(:handle_message)

      consumer.send(:drain_inflight_messages)

      expect(fetch_count).to eq(5) # 5 batches drained (stops when batch is processed, not when empty)
    end

    it 'stops draining after empty batch' do
      msg = double('msg')
      fetch_count = 0

      allow(subscription).to receive(:fetch) do
        fetch_count += 1
        fetch_count <= 2 ? [msg] : []
      end

      allow(processor).to receive(:handle_message)

      consumer.send(:drain_inflight_messages)

      expect(fetch_count).to eq(3) # 2 with messages + 1 empty
    end

    it 'handles error at top level of drain_inflight_messages' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'unexpected error')

      # Should catch outer exception
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end

    it 'catches exceptions from the drain loop itself' do
      # Make Logging.info fail to trigger the outer rescue block
      # The outer rescue handles errors outside the 5.times loop (e.g., logging errors)
      allow(JetstreamBridge::Logging).to receive(:info).and_raise(RuntimeError, 'logging failed')

      # Should handle the error in outer rescue block (line 348)
      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end
  end

  describe 'batch_size parameter handling' do
    it 'converts string batch_size to integer' do
      consumer = described_class.new(batch_size: '50') { |*| nil }
      expect(consumer.batch_size).to eq(50)
    end

    it 'uses DEFAULT_BATCH_SIZE when nil' do
      consumer = described_class.new(batch_size: nil) { |*| nil }
      expect(consumer.batch_size).to eq(described_class::DEFAULT_BATCH_SIZE)
    end

    it 'raises error for invalid batch_size' do
      expect do
        described_class.new(batch_size: 'invalid') { |*| nil }
      end.to raise_error(ArgumentError)
    end
  end

  describe 'middleware chain initialization' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'initializes with empty middleware chain' do
      expect(consumer.middleware_chain).to be_a(JetstreamBridge::Consumer::MiddlewareChain)
    end
  end

  describe '#safe_nak_message' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'calls nak when message responds to it' do
      msg = double('Message')
      allow(msg).to receive(:respond_to?).with(:nak).and_return(true)
      expect(msg).to receive(:nak)

      consumer.send(:safe_nak_message, msg)
    end

    it 'handles messages that do not respond to nak' do
      msg = double('Message')
      allow(msg).to receive(:respond_to?).with(:nak).and_return(false)

      expect { consumer.send(:safe_nak_message, msg) }.not_to raise_error
    end

    it 'catches and logs exceptions from nak' do
      msg = double('Message')
      allow(msg).to receive(:respond_to?).with(:nak).and_return(true)
      allow(msg).to receive(:nak).and_raise(StandardError, 'NAK failed')

      expect(JetstreamBridge::Logging).to receive(:error)
        .with(/Failed to NAK message after crash.*NAK failed/, tag: 'JetstreamBridge::Consumer')

      expect { consumer.send(:safe_nak_message, msg) }.not_to raise_error
    end
  end

  describe '#suggest_gc_if_needed' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'suggests GC when heap_live_slots exceeds threshold' do
      allow(GC).to receive(:respond_to?).with(:stat).and_return(true)
      allow(GC).to receive(:stat).and_return({ heap_live_slots: 150_000 })
      expect(GC).to receive(:start)

      consumer.send(:suggest_gc_if_needed)
    end

    it 'does not suggest GC when below threshold' do
      allow(GC).to receive(:respond_to?).with(:stat).and_return(true)
      allow(GC).to receive(:stat).and_return({ heap_live_slots: 50_000 })
      expect(GC).not_to receive(:start)

      consumer.send(:suggest_gc_if_needed)
    end

    it 'handles GC not being defined' do
      # Hide GC constant temporarily
      gc_backup = Object.const_get(:GC) if Object.const_defined?(:GC)
      Object.send(:remove_const, :GC) if Object.const_defined?(:GC)

      expect { consumer.send(:suggest_gc_if_needed) }.not_to raise_error
    ensure
      Object.const_set(:GC, gc_backup) if gc_backup
    end

    it 'handles GC.stat exceptions' do
      allow(GC).to receive(:respond_to?).with(:stat).and_return(true)
      allow(GC).to receive(:stat).and_raise(StandardError, 'GC.stat failed')

      expect(JetstreamBridge::Logging).to receive(:debug)
        .with(/GC check failed.*GC.stat failed/, tag: 'JetstreamBridge::Consumer')

      expect { consumer.send(:suggest_gc_if_needed) }.not_to raise_error
    end

    it 'handles symbol vs string keys in GC.stat' do
      allow(GC).to receive(:respond_to?).with(:stat).and_return(true)
      # Test with string keys (some Ruby versions use strings)
      allow(GC).to receive(:stat).and_return({ 'heap_live_slots' => 150_000 })
      expect(GC).to receive(:start)

      consumer.send(:suggest_gc_if_needed)
    end
  end

  describe '#memory_usage_mb' do
    subject(:consumer) { described_class.new { |*| nil } }

    it 'returns 0.0 when ps command fails' do
      allow(consumer).to receive(:`).and_raise(StandardError, 'ps command failed')

      result = consumer.send(:memory_usage_mb)
      expect(result).to eq(0.0)
    end

    it 'calculates memory from RSS in KB' do
      # Simulate ps command returning 102400 KB (100 MB)
      allow(consumer).to receive(:`).with(/ps -o rss/).and_return("102400\n")

      result = consumer.send(:memory_usage_mb)
      expect(result).to eq(100.0)
    end
  end

  describe '#drain_inflight_messages additional edge cases' do
    let(:subscription) { double('Subscription') }
    let(:processor) { instance_double(JetstreamBridge::MessageProcessor) }
    subject(:consumer) { described_class.new { |*| nil } }

    before do
      consumer.instance_variable_set(:@psub, subscription)
      consumer.instance_variable_set(:@processor, processor)
    end

    it 'breaks on empty batch' do
      fetch_count = 0
      allow(subscription).to receive(:fetch) do
        fetch_count += 1
        fetch_count == 1 ? [double('Message')] : []
      end
      allow(processor).to receive(:handle_message)

      consumer.send(:drain_inflight_messages)

      expect(fetch_count).to eq(2) # 1 with messages, 1 empty = stop
    end

    it 'logs warning when fetch raises StandardError' do
      allow(subscription).to receive(:fetch).and_raise(StandardError, 'fetch failed')

      expect(JetstreamBridge::Logging).to receive(:warn)
        .with(/Error draining messages.*fetch failed/, tag: 'JetstreamBridge::Consumer')

      expect { consumer.send(:drain_inflight_messages) }.not_to raise_error
    end
  end
end
