# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/consumer/middleware'

RSpec.describe JetstreamBridge::ConsumerMiddleware::MiddlewareChain do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created',
           metadata: double('metadata', trace_id: 'trace-456'),
           deliveries: 1)
  end

  describe '#use' do
    it 'adds middleware to the chain' do
      chain = described_class.new
      middleware = double('middleware')
      result = chain.use(middleware)
      expect(result).to eq(chain)
    end

    it 'allows chaining multiple middleware' do
      chain = described_class.new
      middleware1 = double('middleware1')
      middleware2 = double('middleware2')

      chain.use(middleware1).use(middleware2)
      expect(chain.instance_variable_get(:@middlewares)).to eq([middleware1, middleware2])
    end
  end

  describe '#call' do
    it 'executes single middleware' do
      chain = described_class.new
      called = false
      middleware = double('middleware')
      allow(middleware).to receive(:call) do |evt, &block|
        expect(evt).to eq(event)
        called = true
        block.call(evt)
      end

      handler_called = false
      chain.use(middleware)
      chain.call(event) { |_evt| handler_called = true }

      expect(called).to be true
      expect(handler_called).to be true
    end

    it 'executes multiple middleware in order' do
      chain = described_class.new
      execution_order = []

      middleware1 = double('middleware1')
      allow(middleware1).to receive(:call) do |evt, &block|
        execution_order << :middleware1_before
        block.call(evt)
        execution_order << :middleware1_after
      end

      middleware2 = double('middleware2')
      allow(middleware2).to receive(:call) do |evt, &block|
        execution_order << :middleware2_before
        block.call(evt)
        execution_order << :middleware2_after
      end

      chain.use(middleware1).use(middleware2)
      chain.call(event) { |_evt| execution_order << :handler }

      expect(execution_order).to eq([
                                      :middleware1_before,
                                      :middleware2_before,
                                      :handler,
                                      :middleware2_after,
                                      :middleware1_after
                                    ])
    end

    it 'propagates exceptions from middleware' do
      chain = described_class.new
      middleware = double('middleware')
      allow(middleware).to receive(:call).and_raise(StandardError, 'middleware error')

      chain.use(middleware)
      expect do
        chain.call(event) { |_evt| }
      end.to raise_error(StandardError, 'middleware error')
    end

    it 'propagates exceptions from handler' do
      chain = described_class.new
      middleware = double('middleware')
      allow(middleware).to receive(:call) { |evt, &block| block.call(evt) }

      chain.use(middleware)
      expect do
        chain.call(event) { |_evt| raise StandardError, 'handler error' }
      end.to raise_error(StandardError, 'handler error')
    end

    it 'works with no middleware' do
      chain = described_class.new
      handler_called = false
      chain.call(event) do |evt|
        handler_called = true
        expect(evt).to eq(event)
      end
      expect(handler_called).to be true
    end
  end
end

RSpec.describe JetstreamBridge::ConsumerMiddleware::LoggingMiddleware do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created',
           trace_id: 'trace-456')
  end

  describe '#call' do
    it 'logs start and completion' do
      middleware = described_class.new

      expect(JetstreamBridge::Logging).to receive(:info).with(
        /Processing event test-123 \(user.created\)/,
        tag: 'Consumer'
      )
      expect(JetstreamBridge::Logging).to receive(:info).with(
        /Completed event test-123 in \d+\.\d+s/,
        tag: 'Consumer'
      )

      middleware.call(event) { :success }
    end

    it 'logs errors and re-raises' do
      middleware = described_class.new
      error = StandardError.new('processing failed')

      expect(JetstreamBridge::Logging).to receive(:info).with(
        /Processing event test-123/,
        tag: 'Consumer'
      )
      expect(JetstreamBridge::Logging).to receive(:error).with(
        'Failed event test-123: processing failed',
        tag: 'Consumer'
      )

      expect do
        middleware.call(event) { raise error }
      end.to raise_error(StandardError, 'processing failed')
    end

    it 'measures duration correctly' do
      middleware = described_class.new

      allow(JetstreamBridge::Logging).to receive(:info)

      middleware.call(event) { sleep 0.01 }

      expect(JetstreamBridge::Logging).to have_received(:info).with(
        /Completed event test-123 in \d+\.\d+s/,
        tag: 'Consumer'
      )
    end
  end
end

RSpec.describe JetstreamBridge::ConsumerMiddleware::ErrorHandlingMiddleware do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created')
  end

  describe '#call' do
    it 'calls on_error callback when exception occurs' do
      callback_called = false
      callback_event = nil
      callback_error = nil

      middleware = described_class.new(
        on_error: lambda { |evt, err|
          callback_called = true
          callback_event = evt
          callback_error = err
        }
      )

      error = StandardError.new('processing failed')
      expect do
        middleware.call(event) { raise error }
      end.to raise_error(StandardError, 'processing failed')

      expect(callback_called).to be true
      expect(callback_event).to eq(event)
      expect(callback_error).to eq(error)
    end

    it 'does not call on_error callback on success' do
      callback_called = false
      middleware = described_class.new(
        on_error: ->(_evt, _err) { callback_called = true }
      )

      middleware.call(event) { :success }
      expect(callback_called).to be false
    end

    it 'works without on_error callback' do
      middleware = described_class.new(on_error: nil)

      expect do
        middleware.call(event) { raise StandardError, 'error' }
      end.to raise_error(StandardError, 'error')
    end

    it 'still raises after calling callback' do
      middleware = described_class.new(
        on_error: ->(_evt, _err) {}
      )

      expect do
        middleware.call(event) { raise StandardError, 'must raise' }
      end.to raise_error(StandardError, 'must raise')
    end
  end
end

RSpec.describe JetstreamBridge::ConsumerMiddleware::MetricsMiddleware do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created')
  end

  describe '#call' do
    it 'calls on_success callback with duration' do
      success_called = false
      success_event = nil
      success_duration = nil

      middleware = described_class.new(
        on_success: lambda { |evt, duration|
          success_called = true
          success_event = evt
          success_duration = duration
        }
      )

      middleware.call(event) { sleep 0.01 }

      expect(success_called).to be true
      expect(success_event).to eq(event)
      expect(success_duration).to be > 0
      expect(success_duration).to be < 1
    end

    it 'calls on_failure callback with error' do
      failure_called = false
      failure_event = nil
      failure_error = nil

      middleware = described_class.new(
        on_failure: lambda { |evt, err|
          failure_called = true
          failure_event = evt
          failure_error = err
        }
      )

      error = StandardError.new('processing failed')
      expect do
        middleware.call(event) { raise error }
      end.to raise_error(StandardError, 'processing failed')

      expect(failure_called).to be true
      expect(failure_event).to eq(event)
      expect(failure_error).to eq(error)
    end

    it 'works without callbacks' do
      middleware = described_class.new(on_success: nil, on_failure: nil)

      middleware.call(event) { :success }

      expect do
        middleware.call(event) { raise StandardError, 'error' }
      end.to raise_error(StandardError, 'error')
    end

    it 'does not call on_success when error occurs' do
      success_called = false
      middleware = described_class.new(
        on_success: ->(_evt, _duration) { success_called = true },
        on_failure: ->(_evt, _err) {}
      )

      expect do
        middleware.call(event) { raise StandardError, 'error' }
      end.to raise_error(StandardError)

      expect(success_called).to be false
    end
  end
end

RSpec.describe JetstreamBridge::ConsumerMiddleware::TracingMiddleware do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created',
           metadata: double('metadata', trace_id: 'trace-from-metadata'),
           trace_id: 'trace-from-event')
  end

  describe '#call' do
    it 'uses trace_id from metadata if available' do
      middleware = described_class.new

      allow(event.metadata).to receive(:trace_id).and_return('trace-123')

      middleware.call(event) { :success }
    end

    it 'falls back to event trace_id if metadata trace_id is nil' do
      middleware = described_class.new

      allow(event.metadata).to receive(:trace_id).and_return(nil)
      allow(event).to receive(:trace_id).and_return('fallback-trace')

      middleware.call(event) { :success }
    end

    context 'with Rails CurrentAttributes' do
      before do
        stub_const('ActiveSupport::CurrentAttributes', Class.new)
        stub_const('Current', Class.new)
        allow(Current).to receive(:trace_id=)
        allow(Current).to receive(:trace_id).and_return(nil)
      end

      it 'sets trace_id on Current' do
        middleware = described_class.new

        expect(Current).to receive(:trace_id=).with('trace-from-metadata')

        middleware.call(event) { :success }
      end

      it 'restores previous trace_id after execution' do
        middleware = described_class.new

        allow(Current).to receive(:trace_id).and_return('previous-trace')
        expect(Current).to receive(:trace_id=).with('trace-from-metadata').ordered
        expect(Current).to receive(:trace_id=).with('previous-trace').ordered

        middleware.call(event) { :success }
      end

      it 'restores trace_id even when exception occurs' do
        middleware = described_class.new

        allow(Current).to receive(:trace_id).and_return('previous-trace')
        expect(Current).to receive(:trace_id=).with('trace-from-metadata').ordered
        expect(Current).to receive(:trace_id=).with('previous-trace').ordered

        expect do
          middleware.call(event) { raise StandardError, 'error' }
        end.to raise_error(StandardError)
      end
    end

    context 'without Rails CurrentAttributes' do
      it 'works without ActiveSupport::CurrentAttributes defined' do
        middleware = described_class.new

        hide_const('ActiveSupport::CurrentAttributes') if defined?(ActiveSupport::CurrentAttributes)

        expect { middleware.call(event) { :success } }.not_to raise_error
      end

      it 'works without Current defined' do
        middleware = described_class.new

        stub_const('ActiveSupport::CurrentAttributes', Class.new)
        hide_const('Current') if defined?(Current)

        expect { middleware.call(event) { :success } }.not_to raise_error
      end
    end
  end
end

RSpec.describe JetstreamBridge::ConsumerMiddleware::TimeoutMiddleware do
  let(:event) do
    double('event',
           event_id: 'test-123',
           type: 'user.created',
           deliveries: 1)
  end

  describe '#call' do
    it 'executes block within timeout' do
      middleware = described_class.new(timeout: 1)
      result = nil

      middleware.call(event) { result = :success }

      expect(result).to eq(:success)
    end

    it 'raises ConsumerError when timeout is exceeded' do
      middleware = described_class.new(timeout: 0.01)

      expect do
        middleware.call(event) { sleep 0.1 }
      end.to raise_error(JetstreamBridge::ConsumerError, /timeout after 0.01s/)
    end

    it 'includes event_id in timeout error' do
      middleware = described_class.new(timeout: 0.01)

      begin
        middleware.call(event) { sleep 0.1 }
      rescue JetstreamBridge::ConsumerError => e
        expect(e.event_id).to eq('test-123')
        expect(e.deliveries).to eq(1)
      end
    end

    it 'allows custom timeout value' do
      middleware = described_class.new(timeout: 0.05)

      # Should not timeout
      expect do
        middleware.call(event) { sleep 0.01 }
      end.not_to raise_error

      # Should timeout
      expect do
        middleware.call(event) { sleep 0.1 }
      end.to raise_error(JetstreamBridge::ConsumerError)
    end

    it 'defaults to 30 second timeout' do
      middleware = described_class.new
      expect(middleware.instance_variable_get(:@timeout)).to eq(30)
    end
  end
end
