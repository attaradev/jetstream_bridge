# frozen_string_literal: true

require_relative 'logging'

begin
  require 'nats/io/client'
rescue LoadError
  # NATS not available, PublisherRetryStrategy won't work but that's ok for tests
end

module JetstreamBridge
  # Base retry strategy interface
  class RetryStrategy
    class RetryExhausted < StandardError; end

    def initialize(max_attempts:, backoffs: [], transient_errors: [])
      @max_attempts = max_attempts
      @backoffs = backoffs
      @transient_errors = transient_errors
    end

    # Execute block with retry logic
    # @yield Block to execute with retry
    # @return Result of the block
    # @raise RetryExhausted if all attempts fail
    def execute(context: nil)
      attempts = 0
      last_error = nil

      loop do
        attempts += 1
        begin
          return yield
        rescue *retryable_errors => e
          last_error = e
          raise e if attempts >= @max_attempts

          delay = calculate_delay(attempts, e)
          log_retry(attempts, e, delay, context)
          sleep delay
        end
      end
    rescue StandardError => e
      raise unless retryable?(e)

      raise RetryExhausted, "Failed after #{attempts} attempts: #{e.message}"
    end

    protected

    def calculate_delay(attempt, _error)
      @backoffs[attempt - 1] || @backoffs.last || 1.0
    end

    def retryable_errors
      @transient_errors.empty? ? [StandardError] : @transient_errors
    end

    def retryable?(error)
      retryable_errors.any? { |klass| error.is_a?(klass) }
    end

    def log_retry(attempt, error, delay, context)
      ctx_info = context ? " [#{context}]" : ''
      Logging.warn(
        "Retry #{attempt}/#{@max_attempts}#{ctx_info}: #{error.class} - #{error.message}, " \
        "waiting #{delay}s",
        tag: 'JetstreamBridge::RetryStrategy'
      )
    end
  end

  # Exponential backoff retry strategy
  class ExponentialBackoffStrategy < RetryStrategy
    def initialize(max_attempts: 3, base_delay: 0.1, max_delay: 60, multiplier: 2, transient_errors: [], jitter: true)
      @base_delay = base_delay
      @max_delay = max_delay
      @multiplier = multiplier
      @jitter = jitter
      backoffs = compute_backoffs(max_attempts)
      super(max_attempts: max_attempts, backoffs: backoffs, transient_errors: transient_errors)
    end

    protected

    def calculate_delay(attempt, _error)
      @backoffs[attempt - 1] || @backoffs.last || @base_delay
    end

    private

    def compute_backoffs(max_attempts)
      (0...max_attempts).map do |i|
        delay = @base_delay * (@multiplier**i)
        if @jitter
          # Add up to 10% jitter, but ensure we don't exceed max_delay
          jitter_amount = delay * 0.1 * rand
          delay = [delay + jitter_amount, @max_delay].min
        else
          delay = [delay, @max_delay].min
        end
        delay
      end
    end
  end

  # Linear backoff retry strategy
  class LinearBackoffStrategy < RetryStrategy
    def initialize(max_attempts: 3, delays: [0.25, 1.0, 2.0], transient_errors: [])
      super(max_attempts: max_attempts, backoffs: delays, transient_errors: transient_errors)
    end
  end

  # Publisher-specific retry strategy
  class PublisherRetryStrategy < LinearBackoffStrategy
    TRANSIENT_ERRORS = begin
      errs = []
      if defined?(NATS::IO)
        errs << NATS::IO::Timeout if defined?(NATS::IO::Timeout)
        errs << NATS::IO::Error if defined?(NATS::IO::Error)
        errs << NATS::IO::NoServersError if defined?(NATS::IO::NoServersError)
        errs << NATS::IO::SocketTimeoutError if defined?(NATS::IO::SocketTimeoutError)
        errs << Errno::ECONNREFUSED
      end
      errs
    end.freeze

    def initialize(max_attempts: 2)
      super(
        max_attempts: max_attempts,
        delays: [0.25, 1.0],
        transient_errors: TRANSIENT_ERRORS
      )
    end
  end
end
