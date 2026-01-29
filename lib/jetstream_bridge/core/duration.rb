# frozen_string_literal: true

# JetstreamBridge
#
module JetstreamBridge
  # Utility for parsing human-friendly durations into milliseconds.
  #
  # Uses auto-detection heuristic by default: integers <1000 are treated as
  # seconds, >=1000 as milliseconds. Strings with unit suffixes are supported
  # (e.g., "30s", "500ms", "1h").
  #
  # Examples:
  #   Duration.to_millis(2)                         #=> 2000 (auto: seconds)
  #   Duration.to_millis(1500)                      #=> 1500 (auto: milliseconds)
  #   Duration.to_millis(30, default_unit: :s)      #=> 30000
  #   Duration.to_millis("30s")                     #=> 30000
  #   Duration.to_millis("500ms")                   #=> 500
  #   Duration.to_millis("250us")                   #=> 0
  #   Duration.to_millis("1h")                      #=> 3_600_000
  #   Duration.to_millis(1_500_000_000, default_unit: :ns) #=> 1500
  #
  # Also:
  #   Duration.normalize_list_to_millis(%w[1s 5s 15s]) #=> [1000, 5000, 15000]
  module Duration
    # multipliers to convert 1 unit into milliseconds
    MULTIPLIER_MS = {
      'ns' => 1.0e-6,     # nanoseconds to ms
      'us' => 1.0e-3,     # microseconds to ms
      'µs' => 1.0e-3,     # alt microseconds symbol
      'ms' => 1,          # milliseconds to ms
      's' => 1_000,       # seconds to ms
      'm' => 60_000,      # minutes to ms
      'h' => 3_600_000,   # hours to ms
      'd' => 86_400_000   # days to ms
    }.freeze

    NUMBER_RE = /\A\d[\d_]*\z/
    TOKEN_RE  = /\A(\d[\d_]*(?:\.\d+)?)\s*(ns|us|µs|ms|s|m|h|d)\z/i

    module_function

    # default_unit:
    #   :auto (default: heuristic - <1000 => seconds, >=1000 => milliseconds)
    #   :ms (explicit milliseconds)
    #   :ns, :us, :s, :m, :h, :d (explicit units)
    def to_millis(val, default_unit: :auto)
      case val
      when Integer then int_to_ms(val, default_unit: default_unit)
      when Float   then float_to_ms(val, default_unit: default_unit)
      when String  then string_to_ms(val, default_unit: default_unit)
      else
        raise ArgumentError, "invalid duration type: #{val.class}" unless val.respond_to?(:to_f)

        float_to_ms(val.to_f, default_unit: default_unit)

      end
    end

    # Normalize an array of durations into integer milliseconds.
    def normalize_list_to_millis(values, default_unit: :auto)
      vals = Array(values)
      return [] if vals.empty?

      vals.map { |v| to_millis(v, default_unit: default_unit) }
    end

    # Convert duration-like value to seconds (rounding up, min 1s).
    #
    # Retains the nanosecond heuristic used in SubscriptionManager:
    # extremely large integers (>= 1_000_000_000) are treated as nanoseconds
    # when default_unit is :auto.
    def to_seconds(val, default_unit: :auto)
      return nil if val.nil?

      millis = if val.is_a?(Integer) && default_unit == :auto && val >= 1_000_000_000
                 to_millis(val, default_unit: :ns)
               else
                 to_millis(val, default_unit: default_unit)
               end

      seconds_from_millis(millis)
    end

    # Normalize an array of durations into integer seconds.
    def normalize_list_to_seconds(values, default_unit: :auto)
      vals = Array(values)
      return [] if vals.empty?

      vals.map { |v| to_seconds(v, default_unit: default_unit) }
    end

    # --- internal helpers ---

    def int_to_ms(num, default_unit:)
      coerce_numeric_to_ms(num.to_f, default_unit)
    end

    def float_to_ms(flt, default_unit:)
      coerce_numeric_to_ms(flt, default_unit)
    end

    def string_to_ms(str, default_unit:)
      s = str.strip
      # Plain number strings are treated like integers so the :auto
      # heuristic still applies (<1000 => seconds, >=1000 => ms).
      return int_to_ms(s.delete('_').to_i, default_unit: default_unit) if NUMBER_RE.match?(s)

      m = TOKEN_RE.match(s)
      raise ArgumentError, "invalid duration: #{str.inspect}" unless m

      num   = m[1].delete('_').to_f
      unit  = m[2].downcase
      (num * MULTIPLIER_MS.fetch(unit)).round
    end

    def coerce_numeric_to_ms(num, unit)
      # Handle :auto unit with heuristic: <1000 => seconds, >=1000 => milliseconds
      if unit == :auto
        return (num < 1000 ? num * 1_000 : num).round
      end

      u = unit.to_s
      mult = MULTIPLIER_MS[u]
      raise ArgumentError, "invalid unit for default_unit: #{unit.inspect}" unless mult

      (num * mult).round
    end

    def seconds_from_millis(millis)
      # Always round up to avoid zero-second waits when sub-second durations are provided.
      [(millis / 1000.0).ceil, 1].max
    end
  end
end
