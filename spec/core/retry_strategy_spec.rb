# frozen_string_literal: true

require 'jetstream_bridge'
require 'jetstream_bridge/core/retry_strategy'

RSpec.describe JetstreamBridge::RetryStrategy do
  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'test_app'
      c.env             = 'test'
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
    end
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
