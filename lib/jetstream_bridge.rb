# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/core/config'
require_relative 'jetstream_bridge/core/duration'
require_relative 'jetstream_bridge/core/logging'
require_relative 'jetstream_bridge/core/connection'
require_relative 'jetstream_bridge/publisher/publisher'
require_relative 'jetstream_bridge/publisher/batch_publisher'
require_relative 'jetstream_bridge/consumer/consumer'
require_relative 'jetstream_bridge/consumer/middleware'
require_relative 'jetstream_bridge/models/publish_result'
require_relative 'jetstream_bridge/models/event'

# If you have a Railtie for tasks/eager-loading
require_relative 'jetstream_bridge/railtie' if defined?(Rails::Railtie)

# Load gem-provided models from lib/
require_relative 'jetstream_bridge/models/inbox_event'
require_relative 'jetstream_bridge/models/outbox_event'

# JetStream Bridge - Production-safe realtime data bridge using NATS JetStream.
#
# JetStream Bridge provides a reliable, production-ready way to publish and consume
# events using NATS JetStream with features like:
#
# - Transactional Outbox pattern for guaranteed event publishing
# - Idempotent Inbox pattern for exactly-once message processing
# - Dead Letter Queue (DLQ) for poison message handling
# - Automatic stream provisioning and overlap detection
# - Built-in health checks and monitoring
# - Middleware support for cross-cutting concerns
# - Rails integration with generators and migrations
# - Graceful startup/shutdown lifecycle management
#
# @example Quick start
#   # Configure (automatically starts connection)
#   JetstreamBridge.configure do |config|
#     config.nats_urls = "nats://localhost:4222"
#     config.env = "development"
#     config.app_name = "my_app"
#     config.destination_app = "other_app"
#     config.use_outbox = true
#     config.use_inbox = true
#   end
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
#   at_exit { JetstreamBridge.shutdown! }
#
# @see Publisher For publishing events
# @see Consumer For consuming events
# @see Config For configuration options
# @see TestHelpers For testing utilities
#
module JetstreamBridge
  class << self
    def config
      @config ||= Config.new
    end

    # Configure JetStream Bridge settings and establish connection
    #
    # This method sets configuration and immediately establishes a connection
    # to NATS, providing fail-fast behavior during application startup.
    # If NATS is unavailable, the application will fail to start.
    #
    # Set config.lazy_connect = true to defer connection until first use.
    #
    # @example Basic configuration
    #   JetstreamBridge.configure do |config|
    #     config.nats_urls = "nats://localhost:4222"
    #     config.app_name = "my_app"
    #     config.destination_app = "worker"
    #   end
    #
    # @example With hash overrides
    #   JetstreamBridge.configure(env: 'production', app_name: 'my_app')
    #
    # @example Lazy connection (defer until first use)
    #   JetstreamBridge.configure do |config|
    #     config.nats_urls = "nats://localhost:4222"
    #     config.lazy_connect = true
    #   end
    #
    # @param overrides [Hash] Configuration key-value pairs to set
    # @yield [Config] Configuration object for block-based configuration
    # @return [Config] The configured instance
    # @raise [ConnectionError] If connection to NATS fails (unless lazy_connect is true)
    def configure(overrides = {}, **extra_overrides)
      # Merge extra keyword arguments into overrides hash
      all_overrides = overrides.nil? ? extra_overrides : overrides.merge(extra_overrides)

      cfg = config
      all_overrides.each { |k, v| assign!(cfg, k, v) } unless all_overrides.empty?
      yield(cfg) if block_given?

      # Establish connection immediately for fail-fast behavior (unless lazy_connect is true)
      startup! unless cfg.lazy_connect

      cfg
    end

    # Configure with a preset and establish connection
    #
    # This method applies a configuration preset and immediately establishes
    # a connection to NATS, providing fail-fast behavior.
    #
    # @example
    #   JetstreamBridge.configure_for(:production) do |config|
    #     config.nats_urls = ENV["NATS_URLS"]
    #     config.app_name = "my_app"
    #     config.destination_app = "worker"
    #   end
    #
    # @param preset [Symbol] Preset name (:development, :test, :production, etc.)
    # @yield [Config] Configuration object
    # @return [Config] Configured instance
    # @raise [ConnectionError] If connection to NATS fails
    def configure_for(preset)
      configure do |cfg|
        cfg.apply_preset(preset)
        yield(cfg) if block_given?
      end
    end

    def reset!
      @config = nil
      @connection_initialized = false
    end

    # Initialize the JetStream Bridge connection and topology
    #
    # This method is called automatically by `configure`, but can be called
    # explicitly if needed. It's idempotent and safe to call multiple times.
    #
    # @return [void]
    def startup!
      return if @connection_initialized

      Connection.connect!
      @connection_initialized = true
      Logging.info('JetStream Bridge started successfully', tag: 'JetstreamBridge')
    end

    # Gracefully shutdown the JetStream Bridge connection
    #
    # Closes the NATS connection and cleans up resources. Should be called
    # during application shutdown (e.g., in at_exit or signal handlers).
    #
    # @return [void]
    def shutdown!
      return unless @connection_initialized

      begin
        nc = Connection.nc
        nc&.close if nc&.connected?
        Logging.info('JetStream Bridge shut down gracefully', tag: 'JetstreamBridge')
      rescue StandardError => e
        Logging.error("Error during shutdown: #{e.message}", tag: 'JetstreamBridge')
      ensure
        @connection_initialized = false
      end
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

    # Active health check for monitoring and readiness probes
    #
    # Performs actual operations to verify system health:
    # - Checks NATS connection (active: calls account_info API)
    # - Verifies stream exists and is accessible (active: queries stream info)
    # - Tests NATS round-trip communication (active: RTT measurement)
    #
    # Rate Limiting: To prevent abuse, uncached health checks are limited to once every 5 seconds.
    # Cached results (within 30s TTL) bypass this limit via Connection.instance.connected?.
    #
    # @param skip_cache [Boolean] Force fresh health check, bypass connection cache (rate limited)
    # @return [Hash] Health status including NATS connection, stream, and version
    # @raise [HealthCheckFailedError] If skip_cache requested too frequently
    def health_check(skip_cache: false)
      # Rate limit uncached requests to prevent abuse (max 1 per 5 seconds)
      enforce_health_check_rate_limit! if skip_cache

      start_time = Time.now
      conn_instance = Connection.instance

      # Active check: calls @jts.account_info internally
      # Pass skip_cache to force fresh check if requested
      connected = conn_instance.connected?(skip_cache: skip_cache)
      connected_at = conn_instance.connected_at
      connection_state = conn_instance.state
      last_error = conn_instance.last_reconnect_error
      last_error_at = conn_instance.last_reconnect_error_at

      # Active check: queries actual stream from NATS server
      stream_info = connected ? fetch_stream_info : { exists: false, name: config.stream_name }

      # Active check: measure NATS round-trip time
      rtt_ms = measure_nats_rtt if connected

      health_check_duration_ms = ((Time.now - start_time) * 1000).round(2)

      {
        healthy: connected && stream_info&.fetch(:exists, false),
        connection: {
          state: connection_state,
          connected: connected,
          connected_at: connected_at&.iso8601,
          last_error: last_error&.message,
          last_error_at: last_error_at&.iso8601
        },
        stream: stream_info,
        performance: {
          nats_rtt_ms: rtt_ms,
          health_check_duration_ms: health_check_duration_ms
        },
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
        connection: {
          state: :failed,
          connected: false
        },
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

    # Convenience method to publish events
    #
    # Supports three usage patterns:
    #
    # 1. Structured parameters (recommended):
    #    JetstreamBridge.publish(resource_type: 'user', event_type: 'created', payload: { id: 1, name: 'Ada' })
    #
    # 2. Simplified hash (infers resource_type from event_type):
    #    JetstreamBridge.publish(event_type: 'user.created', payload: { id: 1, name: 'Ada' })
    #
    # 3. Complete envelope (advanced):
    #    JetstreamBridge.publish({ event_type: 'created', resource_type: 'user', payload: {...}, event_id: '...' })
    #
    # @param event_or_hash [Hash, nil] Event hash or first positional argument
    # @param resource_type [String, nil] Resource type (e.g., 'user', 'order')
    # @param event_type [String, nil] Event type (e.g., 'created', 'updated', 'user.created')
    # @param payload [Hash, nil] Event payload data
    # @param subject [String, nil] Optional subject override
    # @param options [Hash] Additional options (event_id, occurred_at, trace_id)
    # @return [Models::PublishResult] Result object with success status and metadata
    #
    # @example Check result status
    #   result = JetstreamBridge.publish(event_type: "user.created", payload: { id: 1 })
    #   if result.success?
    #     puts "Published event #{result.event_id}"
    #   else
    #     logger.error("Publish failed: #{result.error}")
    #   end
    def publish(event_or_hash = nil, resource_type: nil, event_type: nil, payload: nil, subject: nil, **)
      publisher = Publisher.new
      publisher.publish(event_or_hash, resource_type: resource_type, event_type: event_type, payload: payload,
                                       subject: subject, **)
    end

    # Publish variant that raises on error
    #
    # @example
    #   JetstreamBridge.publish!(event_type: "user.created", payload: { id: 1 })
    #   # Raises PublishError if publishing fails
    #
    # @param (see #publish)
    # @return [Models::PublishResult] Result object
    # @raise [PublishError] If publishing fails
    def publish!(...)
      result = publish(...)
      if result.failure?
        raise PublishError.new(result.error&.message, event_id: result.event_id,
                                                      subject: result.subject)
      end

      result
    end

    # Batch publish multiple events efficiently
    #
    # @example
    #   results = JetstreamBridge.publish_batch do |batch|
    #     users.each do |user|
    #       batch.add(event_type: "user.created", payload: { id: user.id })
    #     end
    #   end
    #   puts "Success: #{results.successful_count}, Failed: #{results.failed_count}"
    #
    # @yield [BatchPublisher] Batch publisher instance
    # @return [BatchPublisher::BatchResult] Result with success/failure counts
    def publish_batch
      batch = BatchPublisher.new
      yield(batch) if block_given?
      batch.publish
    end

    # Convenience method to start consuming messages
    #
    # Supports two usage patterns:
    #
    # 1. With a block (recommended):
    #    consumer = JetstreamBridge.subscribe do |event|
    #      puts "Received: #{event.type} on #{event.subject} (attempt #{event.deliveries})"
    #    end
    #    consumer.run!
    #
    # 2. With auto-run (returns Thread):
    #    thread = JetstreamBridge.subscribe(run: true) do |event|
    #      puts "Received: #{event.type}"
    #    end
    #    thread.join # Wait for consumer to finish
    #
    # 3. With a handler object:
    #    handler = ->(event) { puts event.type }
    #    consumer = JetstreamBridge.subscribe(handler)
    #    consumer.run!
    #
    # @param handler [Proc, #call, nil] Message handler (optional if block given)
    # @param run [Boolean] If true, automatically runs consumer in a background thread
    # @param durable_name [String, nil] Optional durable consumer name override
    # @param batch_size [Integer, nil] Optional batch size override
    # @yield [event] Yields Models::Event object to block
    # @return [Consumer, Thread] Consumer instance or Thread if run: true
    def subscribe(handler = nil, run: false, durable_name: nil, batch_size: nil, &block)
      handler ||= block
      raise ArgumentError, 'Handler or block required' unless handler

      consumer = Consumer.new(handler, durable_name: durable_name, batch_size: batch_size)

      if run
        thread = Thread.new { consumer.run! }
        thread.abort_on_exception = true
        thread
      else
        consumer
      end
    end

    private

    # Enforce rate limit on uncached health checks to prevent abuse
    # Max 1 uncached request per 5 seconds per process
    def enforce_health_check_rate_limit!
      @health_check_mutex ||= Mutex.new
      @health_check_mutex.synchronize do
        now = Time.now
        if @last_uncached_health_check
          time_since = now - @last_uncached_health_check
          if time_since < 5
            raise HealthCheckFailedError,
                  "Health check rate limit exceeded. Please wait #{(5 - time_since).ceil} second(s)"
          end
        end
        @last_uncached_health_check = now
      end
    end

    def fetch_stream_info
      jts = Connection.jetstream
      info = jts.stream_info(config.stream_name)

      # Handle both object-style and hash-style access for compatibility
      config_data = info.config
      state_data = info.state
      subjects = config_data.respond_to?(:subjects) ? config_data.subjects : config_data[:subjects]
      messages = state_data.respond_to?(:messages) ? state_data.messages : state_data[:messages]

      {
        exists: true,
        name: config.stream_name,
        subjects: subjects,
        messages: messages
      }
    rescue StandardError => e
      {
        exists: false,
        name: config.stream_name,
        error: "#{e.class}: #{e.message}"
      }
    end

    def measure_nats_rtt
      # Measure round-trip time using NATS RTT method
      nc = Connection.nc
      start = Time.now
      nc.rtt
      ((Time.now - start) * 1000).round(2)
    rescue StandardError => e
      Logging.warn(
        "Failed to measure NATS RTT: #{e.class} #{e.message}",
        tag: 'JetstreamBridge'
      )
      nil
    end

    def assign!(cfg, key, val)
      setter = :"#{key}="
      raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

      cfg.public_send(setter, val)
    end
  end
end
