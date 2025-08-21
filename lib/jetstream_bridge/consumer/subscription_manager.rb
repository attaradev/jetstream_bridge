# frozen_string_literal: true

require_relative '../core/logging'
require_relative '../consumer/consumer_config'

module JetstreamBridge
  # Encapsulates durable ensure + subscribe for a pull consumer.
  class SubscriptionManager
    def initialize(jts, durable, cfg = JetstreamBridge.config)
      @jts     = jts
      @durable = durable
      @cfg     = cfg
    end

    def stream_name
      @cfg.stream_name
    end

    def filter_subject
      @cfg.destination_subject
    end

    def desired_consumer_cfg
      ConsumerConfig.consumer_config(@durable, filter_subject)
    end

    def ensure_consumer!
      info = consumer_info_or_nil
      return create_consumer! unless info
      return log_consumer_ok if consumer_matches?(info, desired_consumer_cfg)

      recreate_consumer!
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

    def consumer_matches?(info, want)
      cfg = info.config
      have = {
        filter_subject: val(cfg, :filter_subject),
        ack_policy: val(cfg, :ack_policy),
        deliver_policy: val(cfg, :deliver_policy),
        max_deliver: int_val(cfg, :max_deliver),
        ack_wait: int_val(cfg, :ack_wait),
        backoff: arr_int(cfg, :backoff)
      }
      want_cmp = {
        filter_subject: want[:filter_subject].to_s,
        ack_policy: want[:ack_policy].to_s,
        deliver_policy: want[:deliver_policy].to_s,
        max_deliver: want[:max_deliver].to_i,
        ack_wait: want[:ack_wait].to_i,
        backoff: Array(want[:backoff]).map(&:to_i)
      }
      have == want_cmp
    end

    def recreate_consumer!
      Logging.warn(
        "Consumer #{@durable} exists with mismatched config; " \
        "recreating (filter=#{filter_subject})",
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

    # ---- cfg helpers (client may return struct-like or hash-like objects) ----

    def val(cfg, key)
      (cfg.respond_to?(key) ? cfg.public_send(key) : cfg[key])&.to_s
    end

    def int_val(cfg, key)
      v = cfg.respond_to?(key) ? cfg.public_send(key) : cfg[key]
      v.to_i
    end

    def arr_int(cfg, key)
      v = cfg.respond_to?(key) ? cfg.public_send(key) : cfg[key]
      Array(v).map(&:to_i)
    end
  end
end
