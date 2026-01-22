# frozen_string_literal: true

require_relative 'core/config'
require_relative 'core/connection_manager'
require_relative 'core/health_checker'
require_relative 'core/logging'
require_relative 'publisher/publisher'
require_relative 'consumer/consumer'
require_relative 'topology/topology'

module JetstreamBridge
  # Facade that coordinates all subsystems
  #
  # Responsible for:
  # - Managing configuration
  # - Managing connection lifecycle
  # - Creating publishers and consumers
  # - Delegating health checks
  class Facade
    attr_reader :config

    def initialize
      @config = Config.new
      @connection_manager = nil
      @publisher = nil
      @health_checker = nil
    end

    # Configure JetStream Bridge
    #
    # @yield [Config] Configuration object
    # @return [Config] The configured instance
    def configure
      yield(@config) if block_given?
      @config
    end

    # Connect to NATS and ensure topology
    #
    # @return [void]
    def connect!
      ensure_connection_manager!
      @connection_manager.connect!
      Logging.info('JetStream Bridge connected successfully', tag: 'JetstreamBridge')
    end

    # Disconnect from NATS
    #
    # @return [void]
    def disconnect!
      return unless @connection_manager

      @connection_manager.disconnect!
      Logging.info('JetStream Bridge disconnected', tag: 'JetstreamBridge')
    end

    # Reconnect to NATS
    #
    # @return [void]
    def reconnect!
      Logging.info('Reconnecting to NATS...', tag: 'JetstreamBridge')
      disconnect!
      connect!
    end

    # Publish an event
    #
    # @param event_type [String] Event type
    # @param payload [Hash] Event payload
    # @param options [Hash] Additional options
    # @return [Models::PublishResult] Result object
    def publish(event_type:, payload:, **)
      connect_if_needed!
      publisher.publish(event_type: event_type, payload: payload, **)
    end

    # Publish a complete event envelope (advanced)
    #
    # @param envelope [Hash] Complete event envelope
    # @param subject [String, nil] Optional subject override
    # @return [Models::PublishResult] Result object
    def publish_envelope(envelope, subject: nil)
      connect_if_needed!
      publisher.publish_envelope(envelope, subject: subject)
    end

    # Subscribe to events
    #
    # @param handler [Proc, #call, nil] Message handler
    # @param options [Hash] Consumer options
    # @yield [event] Optional block as handler
    # @return [Consumer] Consumer instance
    def subscribe(handler = nil, **, &block)
      connect_if_needed!
      create_consumer(handler || block, **)
    end

    # Check if connected to NATS
    #
    # @param skip_cache [Boolean] Force fresh check
    # @return [Boolean] true if connected and healthy
    def connected?(skip_cache: false)
      return false unless @connection_manager

      @connection_manager.connected?(skip_cache: skip_cache)
    rescue StandardError
      false
    end

    # Get comprehensive health status (unified method)
    #
    # Provides complete system health information including connection state,
    # stream info, performance metrics, and configuration.
    #
    # Rate limited to prevent abuse (max 1 uncached check per 5 seconds).
    #
    # @param skip_cache [Boolean] Force fresh health check (rate limited)
    # @return [Hash] Health status including NATS connection, stream, and version
    #
    # @example
    #   health = facade.health
    #   puts "Healthy: #{health[:healthy]}"
    #   puts "Connected: #{health[:connection][:connected]}"
    #   puts "Stream exists: #{health[:stream][:exists]}"
    #   puts "RTT: #{health[:performance][:nats_rtt_ms]}ms"
    def health(skip_cache: false)
      health_checker.check(skip_cache: skip_cache)
    end

    # Backward compatibility: Alias for health method
    #
    # @deprecated Use {#health} instead
    # @param skip_cache [Boolean] Force fresh health check
    # @return [Hash] Health status
    def health_check(skip_cache: false)
      health(skip_cache: skip_cache)
    end

    # Check if system is healthy (convenience method)
    #
    # @return [Boolean] true if connected and stream exists (or JS API disabled)
    #
    # @example
    #   if facade.healthy?
    #     puts "System is healthy and ready"
    #   end
    def healthy?
      health[:healthy]
    rescue StandardError
      false
    end

    # Get stream information
    #
    # @return [Hash] Stream information
    def stream_info
      health_checker.send(:fetch_stream_info)
    end

    private

    def ensure_connection_manager!
      return if @connection_manager

      @config.validate!
      @connection_manager = ConnectionManager.new(@config)
    end

    def connect_if_needed!
      return if @connection_manager&.connected?

      connect!
    end

    # Get or create publisher instance (cached)
    def publisher
      @publisher ||= begin
        ensure_connection_manager!
        Publisher.new(
          connection: @connection_manager.jetstream,
          config: @config
        )
      end
    end

    # Create a new consumer instance (not cached - each subscription is independent)
    def create_consumer(handler, durable_name: nil, batch_size: nil)
      ensure_connection_manager!
      Consumer.new(
        handler,
        connection: @connection_manager.jetstream,
        config: @config,
        durable_name: durable_name,
        batch_size: batch_size
      )
    end

    # Get or create health checker instance (cached)
    def health_checker
      @health_checker ||= begin
        # Try to ensure connection manager, but don't fail if config is invalid
        # HealthChecker will handle the nil connection_manager gracefully
        begin
          ensure_connection_manager!
        rescue ConfigurationError
          # Config not valid yet, health checker will report as unhealthy
        end
        HealthChecker.new(@connection_manager, @config)
      end
    end
  end
end
