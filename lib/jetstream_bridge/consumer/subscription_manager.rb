# frozen_string_literal: true

require 'json'
require_relative '../core/logging'
require_relative '../core/duration'
require_relative '../errors'

module JetstreamBridge
  # Encapsulates durable ensure + subscribe for a pull consumer.
  class SubscriptionManager
    def initialize(jts, durable, cfg = JetstreamBridge.config)
      @jts     = jts
      @durable = durable
      @cfg     = cfg
      @desired_cfg = build_consumer_config(@durable, filter_subject)
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

    def ensure_consumer!(force: false)
      # Runtime path: never hit JetStream management APIs to avoid admin permissions.
      unless force || @cfg.auto_provision
        log_runtime_skip
        return
      end

      create_consumer!
    end

    # Bind a pull subscriber to the existing durable.
    def subscribe!
      # Always bypass consumer_info to avoid requiring JetStream API permissions at runtime.
      subscribe_without_verification!
    end

    def subscribe_without_verification!
      # Manually create a pull subscription without calling consumer_info
      # This bypasses the permission check in nats-pure's pull_subscribe
      nc = resolve_nc

      return build_pull_subscription(nc) if nc.respond_to?(:new_inbox) && nc.respond_to?(:subscribe)

      # Fallback for environments (mocks/tests) where low-level NATS client is unavailable.
      if @jts.respond_to?(:pull_subscribe)
        Logging.info(
          "Using pull_subscribe fallback for consumer #{@durable} (stream=#{stream_name})",
          tag: 'JetstreamBridge::Consumer'
        )
        return @jts.pull_subscribe(filter_subject, @durable, stream: stream_name)
      end

      raise JetstreamBridge::ConnectionError,
            'Unable to create subscription without verification: NATS client not available'
    end

    private

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

    def create_consumer!
      @jts.add_consumer(stream_name, **desired_consumer_cfg)
      Logging.info(
        "Created consumer #{@durable} (filter=#{filter_subject})",
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

    def log_runtime_skip
      Logging.info(
        "Skipping consumer provisioning/verification for #{@durable} at runtime to avoid JetStream API usage. " \
        'Ensure it is pre-created via provisioning.',
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def resolve_nc
      return @jts.nc if @jts.respond_to?(:nc)
      return @jts.instance_variable_get(:@nc) if @jts.instance_variable_defined?(:@nc)

      return @cfg.mock_nats_client if @cfg.respond_to?(:mock_nats_client) && @cfg.mock_nats_client

      nil
    end

    def build_pull_subscription(nats_client)
      prefix = @jts.instance_variable_get(:@prefix) || '$JS.API'
      deliver = nats_client.new_inbox
      sub = nats_client.subscribe(deliver)
      sub.instance_variable_set(:@_jsb_nc, nats_client)
      sub.instance_variable_set(:@_jsb_deliver, deliver)
      sub.instance_variable_set(:@_jsb_next_subject, "#{prefix}.CONSUMER.MSG.NEXT.#{stream_name}.#{@durable}")

      extend_pull_subscription(sub)
      attach_jsi(sub)

      Logging.info(
        "Created pull subscription without verification for consumer #{@durable} " \
        "(stream=#{stream_name}, filter=#{filter_subject})",
        tag: 'JetstreamBridge::Consumer'
      )

      sub
    end

    def extend_pull_subscription(sub)
      pull_mod = begin
        NATS::JetStream.const_get(:PullSubscription)
      rescue NameError
        nil
      end

      sub.extend(pull_mod) if pull_mod
      shim_fetch(sub) unless pull_mod
    end

    def shim_fetch(sub)
      Logging.warn(
        'PullSubscription mixin unavailable; using shim fetch implementation',
        tag: 'JetstreamBridge::Consumer'
      )

      sub.define_singleton_method(:fetch) do |batch_size, timeout: nil|
        nc_handle = instance_variable_get(:@_jsb_nc)
        deliver_subject = instance_variable_get(:@_jsb_deliver)
        next_subject = instance_variable_get(:@_jsb_next_subject)
        unless nc_handle && deliver_subject && next_subject
          raise JetstreamBridge::ConnectionError, 'Missing NATS handles for fetch'
        end

        expires_ns = ((timeout || 5).to_f * 1_000_000_000).to_i
        payload = { batch: batch_size, expires: expires_ns }.to_json

        nc_handle.publish(next_subject, payload, deliver_subject)
        nc_handle.flush

        messages = []
        batch_size.times do
          msg = next_msg(timeout || 5)
          messages << msg if msg
        rescue NATS::IO::Timeout, NATS::Timeout
          break
        end
        messages
      end
    end

    def attach_jsi(sub)
      js_sub_class = begin
        NATS::JetStream.const_get(:JS).const_get(:Sub)
      rescue NameError
        Struct.new(:js, :stream, :consumer, :nms, keyword_init: true)
      end

      sub.jsi = js_sub_class.new(
        js: @jts,
        stream: stream_name,
        consumer: @durable,
        nms: sub.instance_variable_get(:@_jsb_next_subject)
      )
    end
  end
end
