# frozen_string_literal: true

require_relative '../core/logging'
require_relative '../core/duration'

module JetstreamBridge
  # Encapsulates durable ensure + subscribe for a pull consumer.
  class SubscriptionManager
    def initialize(jts, durable, cfg = JetstreamBridge.config)
      @jts     = jts
      @durable = durable
      @cfg     = cfg
      @desired_cfg      = build_consumer_config(@durable, filter_subject)
      @desired_cfg_norm = normalize_consumer_config(@desired_cfg)
    end

    def stream_name
      @cfg.stream_name
    end

    def filter_subject
      @cfg.destination_subject
    end

    def desired_consumer_cfg
      @desired_cfg
    end

    def ensure_consumer!
      info = consumer_info_or_nil
      return create_consumer! unless info

      have_norm = normalize_consumer_config(info.config)
      if have_norm == @desired_cfg_norm
        log_consumer_ok
      else
        log_consumer_diff(have_norm)
        recreate_consumer!
      end
    end

    # Bind a pull subscriber to the existing durable.
    def subscribe!
      @jts.pull_subscribe(
        filter_subject,
        @durable,
        stream: stream_name,
        config: desired_consumer_cfg
      )
    end

    private

    def consumer_info_or_nil
      @jts.consumer_info(stream_name, @durable)
    rescue NATS::JetStream::Error
      nil
    end

    # ---- comparison ----

    def log_consumer_diff(have_norm)
      want_norm = @desired_cfg_norm

      diffs = {}
      (have_norm.keys | want_norm.keys).each do |k|
        diffs[k] = { have: have_norm[k], want: want_norm[k] } unless have_norm[k] == want_norm[k]
      end

      Logging.warn(
        "Consumer #{@durable} config mismatch (filter=#{filter_subject}) diff=#{diffs}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def build_consumer_config(durable, filter_subject)
      {
        durable_name: durable,
        filter_subject: filter_subject,
        ack_policy: 'explicit',
        deliver_policy: 'all',
        max_deliver: JetstreamBridge.config.max_deliver,
        # JetStream expects seconds (the client multiplies by nanoseconds).
        ack_wait: duration_to_seconds(JetstreamBridge.config.ack_wait),
        backoff: Array(JetstreamBridge.config.backoff).map { |d| duration_to_seconds(d) }
      }
    end

    # Normalize both server-returned config objects and our desired hash
    # into a common hash with consistent units/types for accurate comparison.
    def normalize_consumer_config(cfg)
      {
        filter_subject: sval(cfg, :filter_subject), # string
        ack_policy: sval(cfg, :ack_policy), # string
        deliver_policy: sval(cfg, :deliver_policy), # string
        max_deliver: ival(cfg, :max_deliver), # integer
        ack_wait_secs: d_secs(cfg, :ack_wait), # integer seconds
        backoff_secs: darr_secs(cfg, :backoff) # array of integer seconds
      }
    end

    # ---- lifecycle helpers ----

    def recreate_consumer!
      Logging.warn(
        "Consumer #{@durable} exists with mismatched config; recreating (filter=#{filter_subject})",
        tag: 'JetstreamBridge::Consumer'
      )
      safe_delete_consumer
      create_consumer!
    end

    def create_consumer!
      @jts.add_consumer(stream_name, **desired_consumer_cfg)
      Logging.info(
        "Created consumer #{@durable} (filter=#{filter_subject})",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def log_consumer_ok
      Logging.info(
        "Consumer #{@durable} exists with desired config.",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def safe_delete_consumer
      @jts.delete_consumer(stream_name, @durable)
    rescue NATS::JetStream::Error => e
      Logging.warn(
        "Delete consumer #{@durable} ignored: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    # ---- cfg access/normalization (struct-like or hash-like) ----

    def get(cfg, key)
      cfg.respond_to?(key) ? cfg.public_send(key) : cfg[key]
    end

    def sval(cfg, key)
      v = get(cfg, key)
      v = v.to_s if v.is_a?(Symbol)
      v&.to_s&.downcase
    end

    def ival(cfg, key)
      v = get(cfg, key)
      v.to_i
    end

    # Normalize duration-like field to **milliseconds** (Integer).
    # Accepts:
    # - Strings:"500ms""30s" "2m", "1h", "250us", "100ns"
    # - Integers/Floats:
    #     * Server may return large integers in **nanoseconds** → detect and convert.
    #     * Otherwise, we delegate to Duration.to_millis (heuristic/explicit).
    def d_secs(cfg, key)
      raw = get(cfg, key)
      duration_to_seconds(raw)
    end

    # Normalize array of durations to integer milliseconds.
    def darr_secs(cfg, key)
      raw = get(cfg, key)
      Array(raw).map { |d| duration_to_seconds(d) }
    end

    # ---- duration coercion ----

    def duration_to_seconds(val)
      return nil if val.nil?

      case val
      when Integer
        # Heuristic: extremely large integers are likely **nanoseconds** from server
        # (e.g., 30s => 30_000_000_000 ns). Convert ns → seconds.
        return (val / 1_000_000_000.0).round if val >= 1_000_000_000

        # otherwise rely on Duration’s :auto heuristic (int <1000 => seconds, >=1000 => ms)
        millis = Duration.to_millis(val, default_unit: :auto)
        seconds_from_millis(millis)
      when Float
        millis = Duration.to_millis(val, default_unit: :auto)
        seconds_from_millis(millis)
      when String
        # Strings include unit (ns/us/ms/s/m/h/d) handled by Duration
        millis = Duration.to_millis(val) # default_unit ignored when unit given
        seconds_from_millis(millis)
      else
        return duration_to_seconds(val.to_f) if val.respond_to?(:to_f)

        raise ArgumentError, "invalid duration: #{val.inspect}"
      end
    end

    def seconds_from_millis(millis)
      # Always round up to avoid zero-second waits when sub-second durations are provided.
      [(millis / 1000.0).ceil, 1].max
    end
  end
end
