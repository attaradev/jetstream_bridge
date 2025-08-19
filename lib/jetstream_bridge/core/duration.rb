# frozen_string_literal: true

# JetstreamBridge
#
module JetstreamBridge
  # Utility for parsing human-friendly durations into milliseconds.
  # Examples:
  #   Duration.to_millis(30)       #=> 30000
  #   Duration.to_millis("30s")    #=> 30000
  #   Duration.to_millis("500ms")  #=> 500
  #   Duration.to_millis(0.5)      #=> 500
  module Duration
    MULTIPLIER = { 'ms' => 1, 's' => 1_000, 'm' => 60_000, 'h' => 3_600_000 }.freeze
    NUMBER_RE  = /\A\d+\z/.freeze
    TOKEN_RE   = /\A(\d+(?:\.\d+)?)\s*(ms|s|m|h)\z/i.freeze

    module_function

    def to_millis(val)
      return int_to_ms(val) if val.is_a?(Integer)
      return float_to_ms(val) if val.is_a?(Float)
      return string_to_ms(val) if val.is_a?(String)
      return float_to_ms(val.to_f) if val.respond_to?(:to_f)

      raise ArgumentError, "invalid duration type: #{val.class}"
    end

    def int_to_ms(i)
      i >= 1_000 ? i : i * 1_000
    end

    def float_to_ms(f)
      (f * 1_000).round
    end

    def string_to_ms(str)
      s = str.strip
      return int_to_ms(s.to_i) if NUMBER_RE.match?(s)

      m = TOKEN_RE.match(s)
      raise ArgumentError, "invalid duration: #{str.inspect}" unless m

      (m[1].to_f * MULTIPLIER.fetch(m[2].downcase)).round
    end
  end
end
