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
require_relative 'jetstream_bridge/inbox_event'
require_relative 'jetstream_bridge/outbox_event'

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

    # Establishes a connection and ensures stream topology.
    #
    # @return [Object] JetStream context
    def ensure_topology!
      Connection.connect!
      Connection.jetstream
    end

    # Health check for monitoring and readiness probes
    #
    # @return [Hash] Health status including NATS connection, stream, and version
    def health_check
      conn_instance = Connection.instance
      connected = conn_instance.connected?
      connected_at = conn_instance.connected_at

      stream_info = fetch_stream_info if connected

      {
        healthy: connected && stream_info[:exists],
        nats_connected: connected,
        connected_at: connected_at&.iso8601,
        stream: stream_info,
        config: {
          env: config.env,
          app_name: config.app_name,
          destination_app: config.destination_app,
          use_outbox: config.use_outbox,
          use_inbox: config.use_inbox,
          use_dlq: config.use_dlq
        },
        version: JetstreamBridge::VERSION
      }
    rescue StandardError => e
      {
        healthy: false,
        error: "#{e.class}: #{e.message}"
      }
    end

    # Check if connected to NATS
    #
    # @return [Boolean] true if connected and healthy
    def connected?
      Connection.instance.connected?
    rescue StandardError
      false
    end

    # Get stream information for the configured stream
    #
    # @return [Hash] Stream information including subjects and message count
    def stream_info
      fetch_stream_info
    end

    private

    def fetch_stream_info
      jts = Connection.jetstream
      info = jts.stream_info(config.stream_name)
      {
        exists: true,
        name: config.stream_name,
        subjects: info.config.subjects,
        messages: info.state.messages
      }
    rescue StandardError => e
      {
        exists: false,
        name: config.stream_name,
        error: "#{e.class}: #{e.message}"
      }
    end

    def assign!(cfg, key, val)
      setter = :"#{key}="
      raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

      cfg.public_send(setter, val)
    end
  end
end
