# frozen_string_literal: true

require_relative '../core/logging'
require_relative '../consumer/consumer_config'

module JetstreamBridge
  # Encapsulates durable ensure + subscribe for a consumer.
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
      return log_consumer_ok if consumer_matches?(info)

      recreate_consumer!
    end

    private

    def consumer_info_or_nil
      @jts.consumer_info(stream_name, @durable)
    rescue NATS::JetStream::Error
      nil
    end

    def consumer_matches?(info)
      cfg  = info.config
      have = (cfg.respond_to?(:filter_subject) ? cfg.filter_subject : cfg[:filter_subject]).to_s
      want = desired_consumer_cfg[:filter_subject].to_s
      have == want
    end

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
      Logging.info("Created consumer #{@durable} (filter=#{filter_subject})",
                   tag: 'JetstreamBridge::Consumer')
    end

    def log_consumer_ok
      Logging.info("Consumer #{@durable} exists with desired config.",
                   tag: 'JetstreamBridge::Consumer')
    end

    def safe_delete_consumer
      @jts.delete_consumer(stream_name, @durable)
    rescue NATS::JetStream::Error => e
      Logging.warn("Delete consumer #{@durable} ignored: #{e.class} #{e.message}",
                   tag: 'JetstreamBridge::Consumer')
    end
    def subscribe!
      @jts.pull_subscribe(
        filter_subject,
        @durable,
        stream: stream_name,
        config: ConsumerConfig.subscribe_config
      )
    end

    def consumer_mismatch?(info, desired_cfg)
      cfg = info.config
      (cfg.respond_to?(:filter_subject) ? cfg.filter_subject.to_s : cfg[:filter_subject].to_s) !=
        desired_cfg[:filter_subject].to_s
    end
  end
end
