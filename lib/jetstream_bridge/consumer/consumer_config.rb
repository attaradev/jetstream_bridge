# frozen_string_literal: true

require_relative '../core/duration'
require_relative '../core/config'
require_relative '../core/logging'

module JetstreamBridge
  # Consumer configuration helpers.
  module ConsumerConfig
    module_function

    def consumer_config(durable, filter_subject)
      {
        durable_name: durable,
        filter_subject: filter_subject,
        ack_policy: 'explicit',
        max_deliver: JetstreamBridge.config.max_deliver,
        ack_wait: Duration.to_millis(JetstreamBridge.config.ack_wait),
        backoff: Array(JetstreamBridge.config.backoff).map { |d| Duration.to_millis(d) }
      }
    end

    def subscribe_config
      {
        ack_policy: 'explicit',
        max_deliver: JetstreamBridge.config.max_deliver,
        ack_wait: Duration.to_millis(JetstreamBridge.config.ack_wait),
        backoff: Array(JetstreamBridge.config.backoff).map { |d| Duration.to_millis(d) }
      }
    end
  end
end
