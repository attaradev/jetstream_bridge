# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/core'
require_relative 'jetstream_bridge/core/connection_manager'
require_relative 'jetstream_bridge/publisher/event_envelope_builder'
require_relative 'jetstream_bridge/publisher/publisher'
require_relative 'jetstream_bridge/publisher/batch_publisher'
require_relative 'jetstream_bridge/consumer/consumer'
require_relative 'jetstream_bridge/consumer/middleware'
require_relative 'jetstream_bridge/models/publish_result'
require_relative 'jetstream_bridge/models/event'
require_relative 'jetstream_bridge/facade'

# Rails-specific entry point (lifecycle helpers + Railtie)
require_relative 'jetstream_bridge/rails' if defined?(Rails::Railtie)

# Load gem-provided models from lib/
require_relative 'jetstream_bridge/models/inbox_event'
require_relative 'jetstream_bridge/models/outbox_event'

# JetStream Bridge - Production-safe realtime data bridge using NATS JetStream.
#
# @example Quick start
#   # Configure
#   JetstreamBridge.configure do |config|
#     config.nats_urls = "nats://localhost:4222"
#     config.app_name = "my_app"
#     config.destination_app = "other_app"
#     config.stream_name = "MY_STREAM"
#     config.use_outbox = true
#     config.use_inbox = true
#   end
#
#   # Connect (validates config and establishes connection)
#   JetstreamBridge.connect!
#
#   # Publish events
#   JetstreamBridge.publish(
#     event_type: "user.created",
#     payload: { id: 1, email: "ada@example.com" }
#   )
#
#   # Consume events
#   consumer = JetstreamBridge.subscribe do |event|
#     puts "Received: #{event.type} - #{event.payload.to_h}"
#   end
#   consumer.run!
#
#   # Graceful shutdown
#   at_exit { JetstreamBridge.disconnect! }
#
module JetstreamBridge
  class << self
    # Get configuration instance
    #
    # @return [Config] Configuration object
    def config
      facade.config
    end

    # Configure JetStream Bridge settings
    #
    # @yield [Config] Configuration object for block-based configuration
    # @return [Config] The configured instance
    #
    # @example
    #   JetstreamBridge.configure do |config|
    #     config.nats_urls = "nats://localhost:4222"
    #     config.app_name = "my_app"
    #     config.destination_app = "worker"
    #     config.stream_name = "MY_STREAM"
    #   end
    def configure(&)
      facade.configure(&)
    end

    # Connect to NATS and ensure stream topology
    #
    # Validates configuration and establishes connection.
    # Idempotent - safe to call multiple times.
    #
    # @return [void]
    # @raise [ConfigurationError] If configuration is invalid
    # @raise [ConnectionError] If unable to connect
    #
    # @example
    #   JetstreamBridge.connect!
    def connect!
      facade.connect!
    end

    # Disconnect from NATS
    #
    # Closes the NATS connection and cleans up resources.
    #
    # @return [void]
    #
    # @example
    #   at_exit { JetstreamBridge.disconnect! }
    def disconnect!
      facade.disconnect!
    end

    # Reconnect to NATS (disconnect + connect)
    #
    # Useful for:
    # - Forking web servers (Puma, Unicorn) after worker boot
    # - Recovering from connection issues
    #
    # @return [void]
    #
    # @example In Puma configuration
    #   on_worker_boot do
    #     JetstreamBridge.reconnect! if defined?(JetstreamBridge)
    #   end
    def reconnect!
      facade.reconnect!
    end

    # Publish an event
    #
    # Simplified API with single pattern:
    # - event_type: required (e.g., "user.created")
    # - payload: required event data
    # - resource_type: optional (inferred from event_type if dotted notation)
    # - All other fields are optional
    #
    # @param event_type [String] Event type (required)
    # @param payload [Hash] Event payload data (required)
    # @param resource_type [String, nil] Resource type (optional, inferred if nil)
    # @param subject [String, nil] Optional NATS subject override
    # @param options [Hash] Additional options (event_id, occurred_at, trace_id, etc.)
    # @return [Models::PublishResult] Result object with success status and metadata
    #
    # @example Basic publishing
    #   result = JetstreamBridge.publish(
    #     event_type: "user.created",
    #     payload: { id: 1, email: "ada@example.com" }
    #   )
    #   puts "Success!" if result.success?
    #
    # @example With options
    #   result = JetstreamBridge.publish(
    #     event_type: "order.updated",
    #     payload: { id: 123, status: "shipped" },
    #     resource_type: "order",
    #     trace_id: request_id
    #   )
    def publish(event_type:, payload:, **)
      facade.publish(event_type: event_type, payload: payload, **)
    end

    # Publish variant that raises on error
    #
    # @param (see #publish)
    # @return [Models::PublishResult] Result object
    # @raise [PublishError] If publishing fails
    #
    # @example
    #   JetstreamBridge.publish!(event_type: "user.created", payload: { id: 1 })
    def publish!(event_type:, payload:, **)
      result = publish(event_type: event_type, payload: payload, **)
      if result.failure?
        raise PublishError.new(result.error&.message, event_id: result.event_id, subject: result.subject)
      end

      result
    end

    # Publish a complete event envelope (advanced usage)
    #
    # Provides full control over the envelope structure. Use this when you need to
    # manually construct the envelope or preserve all fields from an external source.
    #
    # @param envelope [Hash] Complete event envelope with all required fields
    # @param subject [String, nil] Optional NATS subject override
    # @return [Models::PublishResult] Result object
    #
    # @raise [ArgumentError] If required envelope fields are missing
    #
    # @example Publishing a complete envelope
    #   envelope = {
    #     'event_id' => SecureRandom.uuid,
    #     'schema_version' => 1,
    #     'event_type' => 'user.created',
    #     'producer' => 'custom-producer',
    #     'resource_type' => 'user',
    #     'resource_id' => '123',
    #     'occurred_at' => Time.now.utc.iso8601,
    #     'trace_id' => 'trace-123',
    #     'payload' => { id: 123, name: 'Alice' }
    #   }
    #
    #   result = JetstreamBridge.publish_envelope(envelope)
    #   puts "Published: #{result.event_id}"
    #
    # @example Forwarding events from another system
    #   # Receive event from external system
    #   external_event = external_api.get_event
    #
    #   # Publish as-is, preserving all metadata
    #   JetstreamBridge.publish_envelope(external_event)
    def publish_envelope(envelope, subject: nil)
      facade.publish_envelope(envelope, subject: subject)
    end

    # Subscribe to events
    #
    # @param handler [Proc, #call, nil] Message handler (optional if block given)
    # @param durable_name [String, nil] Optional durable consumer name override
    # @param batch_size [Integer, nil] Optional batch size override
    # @yield [event] Yields Models::Event object to block
    # @return [Consumer] Consumer instance (call run! to start processing)
    #
    # @example With block
    #   consumer = JetstreamBridge.subscribe do |event|
    #     puts "Received: #{event.type} - #{event.payload.to_h}"
    #   end
    #   consumer.run!  # Blocking
    #
    # @example With handler
    #   handler = ->(event) { EventProcessor.process(event) }
    #   consumer = JetstreamBridge.subscribe(handler)
    #   consumer.run!
    def subscribe(handler = nil, durable_name: nil, batch_size: nil, &block)
      raise ArgumentError, 'Handler or block required' unless handler || block

      facade.subscribe(
        handler || block,
        durable_name: durable_name,
        batch_size: batch_size
      )
    end

    # Check if connected to NATS
    #
    # @param skip_cache [Boolean] Force fresh health check
    # @return [Boolean] true if connected and healthy
    #
    # @example
    #   if JetstreamBridge.connected?
    #     puts "Ready to publish"
    #   end
    def connected?(skip_cache: false)
      facade.connected?(skip_cache: skip_cache)
    end

    # Get comprehensive health status (primary method)
    #
    # Provides complete system health including connection state, stream info,
    # performance metrics, and configuration. Use this for monitoring and
    # readiness probes.
    #
    # Rate limited to once every 5 seconds for uncached checks.
    #
    # @param skip_cache [Boolean] Force fresh health check (rate limited)
    # @return [Hash] Health status including connection, stream, performance, config, and version
    #
    # @example Basic health check
    #   health = JetstreamBridge.health
    #   puts "Healthy: #{health[:healthy]}"
    #   puts "State: #{health[:connection][:state]}"
    #   puts "RTT: #{health[:performance][:nats_rtt_ms]}ms"
    #
    # @example Kubernetes readiness probe
    #   def ready
    #     health = JetstreamBridge.health
    #     if health[:healthy]
    #       render json: health, status: :ok
    #     else
    #       render json: health, status: :service_unavailable
    #     end
    #   end
    def health(skip_cache: false)
      facade.health(skip_cache: skip_cache)
    end

    # Backward compatibility alias for health
    #
    # @deprecated Use {#health} instead
    # @param skip_cache [Boolean] Force fresh health check
    # @return [Hash] Health status
    def health_check(skip_cache: false)
      health(skip_cache: skip_cache)
    end

    # Check if system is healthy (convenience method)
    #
    # Returns a simple boolean indicating overall health.
    # Equivalent to `health[:healthy]` but more convenient.
    #
    # @return [Boolean] true if connected and stream exists
    #
    # @example
    #   if JetstreamBridge.healthy?
    #     JetstreamBridge.publish(...)
    #   else
    #     logger.warn "JetStream not healthy, skipping publish"
    #   end
    def healthy?
      facade.healthy?
    end

    # Get stream information
    #
    # @return [Hash] Stream information including subjects and message count
    #
    # @example
    #   info = JetstreamBridge.stream_info
    #   puts "Messages: #{info[:messages]}"
    def stream_info
      facade.stream_info
    end

    # Reset facade (for testing)
    #
    # @api private
    def reset!
      @facade = nil
    end

    private

    def facade
      @facade ||= Facade.new
    end
  end
end
