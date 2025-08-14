# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/config'
require_relative 'jetstream_bridge/duration'
require_relative 'jetstream_bridge/logging'
require_relative 'jetstream_bridge/connection'
require_relative 'jetstream_bridge/publisher'
require_relative 'jetstream_bridge/consumer'

# Rails integration (commands, generators)
require_relative 'jetstream_bridge/railtie' if defined?(Rails)

# JetstreamBridge
#
# Top-level module that exposes configuration and autoloads optional AR models.
# Use `JetstreamBridge.configure` to set defaults for your environment.
module JetstreamBridge
  autoload :OutboxEvent, 'jetstream_bridge/outbox_event'
  autoload :InboxEvent,  'jetstream_bridge/inbox_event'

  class << self
    # Access the global configuration.
    # @return [JetstreamBridge::Config]
    def config
      @config ||= Config.new
    end

    # Configure via hash and/or block.
    # @param overrides [Hash] optional config key/value pairs
    # @yieldparam [JetstreamBridge::Config] config
    # @return [JetstreamBridge::Config]
    def configure(overrides = {})
      cfg = config
      overrides.each { |k, v| assign!(cfg, k, v) }
      yield(cfg) if block_given?
      cfg
    end

    # Reset memoized config (useful in tests).
    def reset!
      @config = nil
    end

    private

    def assign!(cfg, key, val)
      setter = "#{key}="
      raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

      cfg.public_send(setter, val)
    end
  end
end
