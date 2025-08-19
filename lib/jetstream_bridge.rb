# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/core/config'
require_relative 'jetstream_bridge/core/duration'
require_relative 'jetstream_bridge/core/logging'
require_relative 'jetstream_bridge/core/connection'
require_relative 'jetstream_bridge/publisher/publisher'
require_relative 'jetstream_bridge/consumer/consumer'

# If you have a Railtie for tasks/eager-loading
require_relative 'jetstream_bridge/railtie' if defined?(Rails::Railtie)

# Load gem-provided models from lib/
require_relative 'jetstream_bridge/models/outbox_event'
require_relative 'jetstream_bridge/models/inbox_event'


# JetstreamBridge main module.
module JetstreamBridge
  class << self
    def config
      @config ||= Config.new
    end

    def configure(overrides = {})
      cfg = config
      overrides.each { |k, v| assign!(cfg, k, v) } unless overrides.nil? || overrides.empty?
      yield(cfg) if block_given?
      cfg
    end

    def reset!
      @config = nil
    end

    def use_outbox?
      config.use_outbox
    end

    def use_inbox?
      config.use_inbox
    end

    def use_dlq?
      config.use_dlq
    end

    def ensure_topology!
      Connection.connect!
      true
    end

    private

    def assign!(cfg, key, val)
      setter = :"#{key}="
      raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

      cfg.public_send(setter, val)
    end
  end
end
