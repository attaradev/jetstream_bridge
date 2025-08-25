# frozen_string_literal: true

module JetstreamBridge
  class BackoffStrategy
    TRANSIENT_ERRORS = [Timeout::Error, IOError].freeze
    MAX_EXPONENT     = 6
    MAX_DELAY        = 60
    MIN_DELAY        = 1

    # Returns a bounded delay in seconds
    def delay(deliveries, error)
      base = transient?(error) ? 0.5 : 2.0
      power = [deliveries - 1, MAX_EXPONENT].min
      raw = (base * (2**power)).to_i
      raw.clamp(MIN_DELAY, MAX_DELAY)
    end

    private

    def transient?(error)
      TRANSIENT_ERRORS.any? { |k| error.is_a?(k) }
    end
  end
end
