# frozen_string_literal: true

# JetstreamBridge
#
module JetstreamBridge
  # Utility for parsing human-friendly durations into milliseconds.
  #
  # Defaults to an :auto heuristic for Integer/Float values to preserve
  # backward compatibility:
  #   - Integers < 1000 are treated as seconds (e.g., 30 -> 30_000ms)
  #   - Integers >= 1000 are treated as milliseconds (e.g., 1500 -> 1500ms)
  # Prefer setting `default_unit:` to :s or :ms for unambiguous behavior.
  #
  # Examples:
  #   Duration.to_millis(30)                        #=> 30000   (auto)
  #   Duration.to_millis(1500)                      #=> 1500    (auto)
  #   Duration.to_millis("1500")                    #=> 1500    (auto)
  #   Duration.to_millis(1500, default_unit: :s)    #=> 1_500_000
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

    NUMBER_RE = /\A\d[\d_]*\z/.freeze
    TOKEN_RE  = /\A(\d[\d_]*(?:\.\d+)?)\s*(ns|us|µs|ms|s|m|h|d)\z/i.freeze

    module_function

    # default_unit:
    #   :auto (heuristic: int<1000 -> seconds, >=1000 -> ms)
    #   :ns, :us, :ms, :s, :m, :h, :d (explicit)
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

    # --- internal helpers ---

    def int_to_ms(num, default_unit:)
      case default_unit
      when :auto
        # Preserve existing heuristic for compatibility
        num >= 1_000 ? num : num * 1_000
      else
        coerce_numeric_to_ms(num.to_f, default_unit)
      end
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
      case unit
      when :auto
        # For floats, :auto treats as seconds (common developer intent)
        (num * 1_000).round
      else
        u = unit.to_s
        mult = MULTIPLIER_MS[u]
        raise ArgumentError, "invalid unit for default_unit: #{unit.inspect}" unless mult

        (num * mult).round
      end
    end
  end
end
