# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/config'
require_relative 'jetstream_bridge/publisher'
require_relative 'jetstream_bridge/consumer'

# JetstreamBridge
#
# A production-safe bridge for real-time data synchronization over NATS JetStream.
#
# - Publisher: builds envelopes and publishes to subjects derived from env + source_app.
# - Consumer:  durable pull consumer with backoff, DLQ, and optional Inbox idempotency.
# - Optional AR models (autoloaded): Outbox (exactly-once publisher) and Inbox (idempotent consumer).
#
# @example Configure once (e.g., in Rails initializer)
#   JetstreamBridge.configure do |c|
#     c.env             = "production"
#     c.app_name        = "pwas"
#     c.source_app      = "pwas"  # this app publishes as "pwas"
#     c.destination_app = "hw"    # this app consumes from "hw"
#     c.nats_urls       = "nats://n1:4222,nats://n2:4222"
#     c.ack_wait        = "30s"
#     c.backoff         = %w[1s 5s 15s 30s 60s]
#   end
#
# @example Publish an event
#   JetstreamBridge::Publisher.new.publish(
#     resource_type: "user",
#     event_type:    "updated",
#     payload:       { id: 123, name: "Ada" }
#   )
#
# @example Run a consumer (defaults to destination_app as the source filter)
#   JetstreamBridge::Consumer.new(durable_name: "prod-hw-worker") do |event, subject, deliveries|
#     handle(event)
#   end.run!
#
# @note ActiveRecord is only required if you enable Inbox/Outbox.
#
module JetstreamBridge
  # Do NOT eagerly require these; they need ActiveRecord and are optional.
  autoload :OutboxEvent, 'jetstream_bridge/outbox_event'
  autoload :InboxEvent,  'jetstream_bridge/inbox_event'

  class << self
    # @return [JetstreamBridge::Config]
    def config
      @config ||= Config.new
    end

    # Configure the library.
    #
    # Can be used with a block or a hash of overrides:
    #
    # @example Block usage
    #   JetstreamBridge.configure do |c|
    #     c.app_name = "pwas"
    #     c.env      = "production"
    #   end
    #
    # @example Hash usage
    #   JetstreamBridge.configure(app_name: "pwas", env: "production")
    #
    # @param overrides [Hash] optional config key/value pairs
    # @yieldparam [JetstreamBridge::Config] config
    # @return [JetstreamBridge::Config]
    def configure(overrides = {})
      cfg = config

      # Apply hash overrides first
      overrides.each do |key, value|
        raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?("#{key}=")

        cfg.public_send("#{key}=", value)
      end

      # Yield for block configuration
      yield(cfg) if block_given?

      cfg
    end

    # @return [String] current publishing identity
    def source_app
      config.source_app || config.app_name
    end

    # @return [String, nil] default peer we consume FROM
    def destination_app
      config.destination_app
    end

    # Reset memoized config (useful in tests/console)
    # @return [void]
    def reset!
      @config = nil
    end
  end
end
