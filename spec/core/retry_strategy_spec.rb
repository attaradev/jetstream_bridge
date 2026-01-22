# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/core/retry_strategy'

RSpec.describe JetstreamBridge::RetryStrategy do
  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'test_app'
    end
  end

  after { JetstreamBridge.reset! }
  describe '#execute' do
    let(:strategy) do
      described_class.new(
        max_attempts: 3,
        backoffs: [0.001, 0.002, 0.003],
        transient_errors: [StandardError]
      )
    end

    context 'when operation succeeds' do
      it 'returns the result immediately' do
        result = strategy.execute { 'success' }

        expect(result).to eq('success')
      end

      it 'does not retry on success' do
        attempts = 0
        strategy.execute { attempts += 1 }

        expect(attempts).to eq(1)
      end
    end

    context 'when operation fails then succeeds' do
      it 'retries until success' do
        attempts = 0
        result = strategy.execute do
          attempts += 1
          raise StandardError, 'fail' if attempts < 3

          'success'
        end

        expect(result).to eq('success')
        expect(attempts).to eq(3)
      end

      it 'uses backoff delays between retries' do
        allow(strategy).to receive(:sleep)
        attempts = 0

        strategy.execute do
          attempts += 1
          raise StandardError if attempts < 2

          'done'
        end

        expect(strategy).to have_received(:sleep).with(0.001)
      end
    end

    context 'when operation fails consistently' do
      it 'raises RetryExhausted after max attempts' do
        attempts = 0

        expect do
          strategy.execute do
            attempts += 1
            raise StandardError, 'always fails'
          end
        end.to raise_error(JetstreamBridge::RetryStrategy::RetryExhausted, /always fails/)

        expect(attempts).to eq(3)
      end
    end

    context 'with non-retryable errors' do
      let(:strategy) do
        described_class.new(
          max_attempts: 3,
          backoffs: [0.001],
          transient_errors: [IOError]
        )
      end

      it 'raises immediately without retry' do
        attempts = 0

        expect do
          strategy.execute do
            attempts += 1
            raise StandardError, 'not retryable'
          end
        end.to raise_error(StandardError, 'not retryable')

        expect(attempts).to eq(1)
      end
    end

    context 'with context' do
      it 'passes context to log_retry' do
        allow(strategy).to receive(:log_retry)
        attempts = 0

        begin
          strategy.execute(context: 'operation-123') do
            attempts += 1
            raise StandardError if attempts < 2
          end
        rescue JetstreamBridge::RetryStrategy::RetryExhausted
          # Expected
        end

        expect(strategy).to have_received(:log_retry).with(1, anything, anything, 'operation-123')
      end
    end
  end

  describe '#calculate_delay' do
    let(:strategy) do
      described_class.new(
        max_attempts: 3,
        backoffs: [0.5, 1.0, 2.0]
      )
    end

    it 'returns delay from backoffs array' do
      delay = strategy.send(:calculate_delay, 1, StandardError.new)

      expect(delay).to eq(0.5)
    end

    it 'returns second delay for second attempt' do
      delay = strategy.send(:calculate_delay, 2, StandardError.new)

      expect(delay).to eq(1.0)
    end

    it 'returns last delay if attempts exceed backoffs length' do
      delay = strategy.send(:calculate_delay, 10, StandardError.new)

      expect(delay).to eq(2.0)
    end
  end

  describe '#retryable_errors' do
    it 'defaults to StandardError when no transient_errors specified' do
      strategy = described_class.new(max_attempts: 1, backoffs: [], transient_errors: [])

      expect(strategy.send(:retryable_errors)).to eq([StandardError])
    end

    it 'returns transient_errors when specified' do
      strategy = described_class.new(
        max_attempts: 1,
        backoffs: [],
        transient_errors: [IOError, ArgumentError]
      )

      expect(strategy.send(:retryable_errors)).to eq([IOError, ArgumentError])
    end
  end

  describe '#retryable?' do
    it 'returns true for retryable error classes' do
      strategy = described_class.new(
        max_attempts: 1,
        backoffs: [],
        transient_errors: [IOError, ArgumentError]
      )

      expect(strategy.send(:retryable?, IOError.new)).to be true
      expect(strategy.send(:retryable?, ArgumentError.new)).to be true
    end

    it 'returns false for non-retryable error classes' do
      strategy = described_class.new(
        max_attempts: 1,
        backoffs: [],
        transient_errors: [IOError]
      )

      expect(strategy.send(:retryable?, StandardError.new)).to be false
    end

    it 'returns true for subclasses of retryable errors' do
      strategy = described_class.new(
        max_attempts: 1,
        backoffs: [],
        transient_errors: [StandardError]
      )

      expect(strategy.send(:retryable?, ArgumentError.new)).to be true
    end
  end

  describe '#log_retry' do
    it 'logs retry attempts with context' do
      strategy = described_class.new(max_attempts: 3, backoffs: [0.1])
      error = StandardError.new('test error')

      expect do
        strategy.send(:log_retry, 1, error, 0.5, 'test-context')
      end.not_to raise_error
    end

    it 'logs retry attempts without context' do
      strategy = described_class.new(max_attempts: 3, backoffs: [0.1])
      error = StandardError.new('test error')

      expect do
        strategy.send(:log_retry, 2, error, 1.0, nil)
      end.not_to raise_error
    end
  end
end

RSpec.describe JetstreamBridge::ExponentialBackoffStrategy do
  describe '#initialize' do
    it 'sets max_attempts' do
      strategy = described_class.new(max_attempts: 5)

      expect(strategy.instance_variable_get(:@max_attempts)).to eq(5)
    end

    it 'sets backoffs with exponential growth' do
      strategy = described_class.new(max_attempts: 4, base_delay: 1.0)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs.length).to eq(4)
      expect(backoffs[0]).to be_between(1.0, 1.5)    # ~1s + jitter
      expect(backoffs[1]).to be_between(2.0, 2.5)    # ~2s + jitter
      expect(backoffs[2]).to be_between(4.0, 4.5)    # ~4s + jitter
    end

    it 'caps delays at max_delay' do
      strategy = described_class.new(max_attempts: 10, base_delay: 1.0, max_delay: 5.0)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs.all? { |d| d <= 5.0 }).to be true
    end

    it 'supports disabling jitter' do
      strategy = described_class.new(max_attempts: 3, base_delay: 1.0, multiplier: 2, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([1.0, 2.0, 4.0])
    end

    it 'applies jitter when enabled' do
      strategy = described_class.new(max_attempts: 3, base_delay: 1.0, multiplier: 2, jitter: true)
      backoffs = strategy.instance_variable_get(:@backoffs)

      # With jitter, delays should vary slightly
      expect(backoffs[0]).to be_between(1.0, 1.1)
      expect(backoffs[1]).to be_between(2.0, 2.2)
    end

    it 'respects custom multiplier' do
      strategy = described_class.new(max_attempts: 3, base_delay: 1.0, multiplier: 3, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([1.0, 3.0, 9.0])
    end

    it 'respects custom base_delay' do
      strategy = described_class.new(max_attempts: 2, base_delay: 0.5, multiplier: 2, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([0.5, 1.0])
    end

    it 'caps exponential growth at max_delay even without jitter' do
      strategy = described_class.new(max_attempts: 5, base_delay: 10.0, multiplier: 2, max_delay: 30.0, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([10.0, 20.0, 30.0, 30.0, 30.0])
    end

    it 'handles transient_errors parameter' do
      strategy = described_class.new(max_attempts: 2, transient_errors: [IOError, ArgumentError])
      transient = strategy.instance_variable_get(:@transient_errors)

      expect(transient).to eq([IOError, ArgumentError])
    end
  end

  describe '#execute' do
    it 'uses exponential backoff between retries' do
      strategy = described_class.new(max_attempts: 3, base_delay: 0.01)
      allow(strategy).to receive(:sleep)

      attempts = 0
      begin
        strategy.execute do
          attempts += 1
          raise StandardError
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      expect(strategy).to have_received(:sleep).twice
    end
  end
end

RSpec.describe JetstreamBridge::LinearBackoffStrategy do
  describe '#initialize' do
    it 'sets linear delays' do
      strategy = described_class.new(max_attempts: 3, delays: [1.0, 2.0, 3.0])
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([1.0, 2.0, 3.0])
    end

    it 'uses default delays if none provided' do
      strategy = described_class.new(max_attempts: 3)
      backoffs = strategy.instance_variable_get(:@backoffs)

      expect(backoffs).to eq([0.25, 1.0, 2.0])
    end
  end

  describe '#execute' do
    it 'uses linear backoff between retries' do
      strategy = described_class.new(max_attempts: 3, delays: [0.01, 0.02, 0.03])
      allow(strategy).to receive(:sleep)

      attempts = 0
      begin
        strategy.execute do
          attempts += 1
          raise StandardError
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      expect(strategy).to have_received(:sleep).twice
      expect(strategy).to have_received(:sleep).with(0.01)
      expect(strategy).to have_received(:sleep).with(0.02)
    end
  end
end

RSpec.describe JetstreamBridge::PublisherRetryStrategy do
  describe '#initialize' do
    it 'creates strategy with default values' do
      strategy = described_class.new

      expect(strategy).to be_a(JetstreamBridge::LinearBackoffStrategy)
      expect(strategy.instance_variable_get(:@max_attempts)).to eq(2)
    end

    it 'sets transient errors for NATS operations' do
      strategy = described_class.new
      transient = strategy.instance_variable_get(:@transient_errors)

      # Will be empty if NATS is not loaded, which is fine
      expect(transient).to be_an(Array)
    end

    it 'allows custom max_attempts' do
      strategy = described_class.new(max_attempts: 5)

      expect(strategy.instance_variable_get(:@max_attempts)).to eq(5)
    end
  end

  describe 'TRANSIENT_ERRORS' do
    it 'is frozen' do
      expect(described_class::TRANSIENT_ERRORS).to be_frozen
    end

    it 'is an array' do
      expect(described_class::TRANSIENT_ERRORS).to be_an(Array)
    end

    context 'when NATS is available', if: defined?(NATS::IO) do
      it 'includes NATS error classes' do
        errors = described_class::TRANSIENT_ERRORS

        expect(errors).to include(NATS::IO::Timeout) if defined?(NATS::IO::Timeout)
        expect(errors).to include(NATS::IO::Error) if defined?(NATS::IO::Error)
        expect(errors).to include(NATS::IO::NoServersError) if defined?(NATS::IO::NoServersError)
        expect(errors).to include(Errno::ECONNREFUSED)
      end

      it 'includes all expected NATS error types when available' do
        errors = described_class::TRANSIENT_ERRORS
        # Should have at least 4 entries when NATS is available:
        # NATS::IO::Timeout, NATS::IO::Error, NATS::IO::NoServersError,
        # NATS::IO::SocketTimeoutError, Errno::ECONNREFUSED
        expect(errors.size).to be >= 4
      end

      it 'includes NATS::IO::Timeout when defined' do
        skip 'NATS::IO::Timeout not defined' unless defined?(NATS::IO::Timeout)
        expect(described_class::TRANSIENT_ERRORS).to include(NATS::IO::Timeout)
      end

      it 'includes NATS::IO::Error when defined' do
        skip 'NATS::IO::Error not defined' unless defined?(NATS::IO::Error)
        expect(described_class::TRANSIENT_ERRORS).to include(NATS::IO::Error)
      end

      it 'includes NATS::IO::NoServersError when defined' do
        skip 'NATS::IO::NoServersError not defined' unless defined?(NATS::IO::NoServersError)
        expect(described_class::TRANSIENT_ERRORS).to include(NATS::IO::NoServersError)
      end

      it 'includes NATS::IO::SocketTimeoutError when defined' do
        skip 'NATS::IO::SocketTimeoutError not defined' unless defined?(NATS::IO::SocketTimeoutError)
        expect(described_class::TRANSIENT_ERRORS).to include(NATS::IO::SocketTimeoutError)
      end

      it 'includes Errno::ECONNREFUSED' do
        expect(described_class::TRANSIENT_ERRORS).to include(Errno::ECONNREFUSED)
      end

      it 'does not include duplicates' do
        expect(described_class::TRANSIENT_ERRORS).to eq(described_class::TRANSIENT_ERRORS.uniq)
      end
    end

    context 'when NATS is not available', unless: defined?(NATS::IO) do
      it 'has an empty array' do
        # When NATS::IO is not defined, TRANSIENT_ERRORS will be empty
        expect(described_class::TRANSIENT_ERRORS).to eq([])
      end
    end

    # NOTE: The individual defined?() checks for specific NATS error classes
    # (lines 119-122 in retry_strategy.rb) have uncovered else branches.
    # These are defensive checks for partial NATS installations and execute
    # at class load time. In a properly installed NATS environment, these
    # else branches never execute, making them effectively unreachable in tests.
    #
    # Branch coverage details:
    # - Line 118: if defined?(NATS::IO) - both branches covered by context conditions
    # - Lines 119-122: Individual defined?() checks - only "then" branches are reachable
    #   when NATS is properly installed. The "else" branches would only execute in
    #   malformed NATS installations where NATS::IO exists but error classes don't.
  end

  describe '#execute' do
    let(:strategy) { described_class.new(max_attempts: 3) }

    it 'retries on transient errors', if: defined?(NATS::IO) do
      allow(strategy).to receive(:sleep)
      attempts = 0

      result = strategy.execute do
        attempts += 1
        raise NATS::IO::Timeout if attempts < 2

        'published'
      end

      expect(result).to eq('published')
      expect(attempts).to eq(2)
    end

    it 'does not retry non-transient errors' do
      attempts = 0

      expect do
        strategy.execute do
          attempts += 1
          raise ArgumentError, 'invalid subject'
        end
      end.to raise_error(ArgumentError, 'invalid subject')

      expect(attempts).to eq(1)
    end
  end
end

RSpec.describe JetstreamBridge::RetryStrategy, 'branch coverage' do
  describe 'retryable_errors branches' do
    it 'returns [StandardError] when transient_errors is empty' do
      strategy = described_class.new(max_attempts: 2, transient_errors: [])
      expect(strategy.send(:retryable_errors)).to eq([StandardError])
    end

    it 'returns transient_errors when not empty' do
      strategy = described_class.new(max_attempts: 2, transient_errors: [ArgumentError, RuntimeError])
      expect(strategy.send(:retryable_errors)).to eq([ArgumentError, RuntimeError])
    end
  end

  describe 'log_retry with context' do
    it 'includes context in log message when provided' do
      strategy = described_class.new(max_attempts: 3)
      allow(strategy).to receive(:sleep)
      allow(JetstreamBridge::Logging).to receive(:warn)

      attempts = 0
      begin
        strategy.execute(context: 'user.created') do
          attempts += 1
          raise StandardError, 'test error' if attempts < 3
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      # Should be called twice (for 2 retries before exhausting)
      expect(JetstreamBridge::Logging).to have_received(:warn).with(
        include('[user.created]'),
        tag: 'JetstreamBridge::RetryStrategy'
      ).twice
    end

    it 'omits context from log message when not provided' do
      strategy = described_class.new(max_attempts: 3)
      allow(strategy).to receive(:sleep)
      allow(JetstreamBridge::Logging).to receive(:warn)

      attempts = 0
      begin
        strategy.execute do
          attempts += 1
          raise StandardError, 'test error' if attempts < 3
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      # Verify it was called without any context markers (no brackets)
      expect(JetstreamBridge::Logging).to have_received(:warn).with(
        %r{Retry \d+/\d+: StandardError - test error, waiting},
        tag: 'JetstreamBridge::RetryStrategy'
      ).twice

      # Ensure no calls included brackets
      expect(JetstreamBridge::Logging).not_to have_received(:warn).with(
        /\[.*\]/,
        anything
      )
    end
  end

  describe 'backoff fallback logic' do
    it 'uses backoffs.last when attempt exceeds array length' do
      strategy = described_class.new(max_attempts: 5, backoffs: [0.1, 0.2])
      allow(strategy).to receive(:sleep)

      attempts = 0
      begin
        strategy.execute do
          attempts += 1
          raise StandardError
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      # Should use 0.1, 0.2, 0.2, 0.2 (last value repeated)
      expect(strategy).to have_received(:sleep).with(0.1).once
      expect(strategy).to have_received(:sleep).with(0.2).exactly(3).times
    end

    it 'uses 1.0 default when backoffs is empty' do
      strategy = described_class.new(max_attempts: 3, backoffs: [])
      allow(strategy).to receive(:sleep)

      attempts = 0
      begin
        strategy.execute do
          attempts += 1
          raise StandardError
        end
      rescue JetstreamBridge::RetryStrategy::RetryExhausted
        # Expected
      end

      expect(strategy).to have_received(:sleep).with(1.0).twice
    end
  end
end

RSpec.describe JetstreamBridge::ExponentialBackoffStrategy, 'branch coverage' do
  describe 'jitter branches' do
    it 'applies jitter when jitter is true' do
      strategy = described_class.new(max_attempts: 3, base_delay: 0.1, jitter: true)
      backoffs = strategy.instance_variable_get(:@backoffs)

      # With jitter, delays should vary slightly
      # We can't test exact values due to randomness, but we can verify they're computed
      expect(backoffs.size).to eq(3)
      expect(backoffs[0]).to be >= 0.1
      expect(backoffs[0]).to be <= 0.11 # 0.1 + 10% jitter
    end

    it 'does not apply jitter when jitter is false' do
      strategy = described_class.new(max_attempts: 3, base_delay: 0.1, multiplier: 2, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      # Without jitter, delays should be exact exponential values
      expect(backoffs[0]).to eq(0.1)
      expect(backoffs[1]).to eq(0.2)
      expect(backoffs[2]).to eq(0.4)
    end

    it 'respects max_delay with jitter' do
      strategy = described_class.new(max_attempts: 5, base_delay: 10, max_delay: 15, jitter: true)
      backoffs = strategy.instance_variable_get(:@backoffs)

      # All delays should be capped at max_delay
      backoffs.each do |delay|
        expect(delay).to be <= 15
      end
    end

    it 'respects max_delay without jitter' do
      strategy = described_class.new(max_attempts: 5, base_delay: 10, multiplier: 3, max_delay: 15, jitter: false)
      backoffs = strategy.instance_variable_get(:@backoffs)

      # Should be [10, 15, 15, 15, 15] (capped at 15)
      expect(backoffs[0]).to eq(10)
      expect(backoffs[1]).to eq(15)
      expect(backoffs[2]).to eq(15)
    end
  end

  describe 'calculate_delay fallback' do
    it 'uses base_delay when backoffs array is exhausted' do
      strategy = described_class.new(max_attempts: 2, base_delay: 0.5)
      # Access protected method for testing
      delay = strategy.send(:calculate_delay, 10, StandardError.new)

      backoffs = strategy.instance_variable_get(:@backoffs)
      expect(delay).to eq(backoffs.last)
    end
  end
end
