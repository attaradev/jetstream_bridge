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
      unless @cfg.disable_js_api
      @desired_cfg      = build_consumer_config(@durable, filter_subject)
      @desired_cfg_norm = normalize_consumer_config(@desired_cfg)
      end
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
      if @cfg.disable_js_api
        Logging.info("JS API disabled; assuming consumer #{@durable} exists", tag: 'JetstreamBridge::Consumer')
        return
      end

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
      opts = { stream: stream_name }
      if @cfg.disable_js_api
        opts[:bind] = true
      else
        opts[:config] = desired_consumer_cfg
      end

      @jts.pull_subscribe(
        filter_subject,
        @durable,
        **opts
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
        # JetStream expects nanoseconds for ack_wait/backoff.
        ack_wait: duration_to_nanos(JetstreamBridge.config.ack_wait),
        backoff: Array(JetstreamBridge.config.backoff).map { |d| duration_to_nanos(d) }
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
        ack_wait_nanos: nanos(cfg, :ack_wait),
        backoff_nanos: nanos_arr(cfg, :backoff)
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

    # ---- duration coercion ----

    def nanos(cfg, key)
      raw = get(cfg, key)
      duration_to_nanos(raw)
    end

    def nanos_arr(cfg, key)
      raw = get(cfg, key)
      Array(raw).map { |d| duration_to_nanos(d) }
    end

    def duration_to_nanos(val)
      return nil if val.nil?

      case val
      when Integer
        # Heuristic: extremely large integers are likely already nanoseconds
        return val if val >= 1_000_000_000 # >= 1s in nanos
        millis = Duration.to_millis(val, default_unit: :auto)
        (millis * 1_000_000).to_i
      when Float
        millis = Duration.to_millis(val, default_unit: :auto)
        (millis * 1_000_000).to_i
      when String
        millis = Duration.to_millis(val) # unit-aware
        (millis * 1_000_000).to_i
      else
        return duration_to_nanos(val.to_f) if val.respond_to?(:to_f)

        raise ArgumentError, "invalid duration: #{val.inspect}"
      end
    end

    # Legacy helper used in specs; kept for backward compatibility.
    def duration_to_seconds(val)
      return nil if val.nil?

      case val
      when Integer
        return (val / 1_000_000_000.0).round if val >= 1_000_000_000 # nanoseconds
        return val if val < 1000 # seconds
        (val / 1000.0).round # milliseconds as integer
      when Float
        val
      else
        millis = Duration.to_millis(val, default_unit: :auto)
        seconds = millis / 1000.0
        seconds < 1 ? 1 : seconds.round(3)
      end
    end
  end
end
