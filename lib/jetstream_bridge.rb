# frozen_string_literal: true

require_relative 'jetstream_bridge/version'
require_relative 'jetstream_bridge/core/config'
require_relative 'jetstream_bridge/core/duration'
require_relative 'jetstream_bridge/core/logging'
require_relative 'jetstream_bridge/core/connection'
require_relative 'jetstream_bridge/publisher/publisher'
require_relative 'jetstream_bridge/publisher/batch_publisher'
require_relative 'jetstream_bridge/consumer/consumer'
require_relative 'jetstream_bridge/models/publish_result'
require_relative 'jetstream_bridge/models/event'

# If you have a Railtie for tasks/eager-loading
require_relative 'jetstream_bridge/railtie' if defined?(Rails::Railtie)

# Load gem-provided models from lib/
require_relative 'jetstream_bridge/models/inbox_event'
require_relative 'jetstream_bridge/models/outbox_event'

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

    # Configure with a preset
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
    def configure_for(preset, &block)
      configure do |cfg|
        cfg.apply_preset(preset)
        yield(cfg) if block_given?
      end
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
      raise PublishError.new(result.error&.message, event_id: result.event_id, subject: result.subject) if result.failure?

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
    def publish_batch(&block)
      batch = BatchPublisher.new
      yield(batch) if block_given?
      batch.publish
    end

    # Convenience method to start consuming messages
    #
    # Supports two usage patterns:
    #
    # 1. With a block (recommended):
    #    consumer = JetstreamBridge.subscribe do |event, subject, deliveries|
    #      puts "Received: #{event['event_type']} on #{subject} (attempt #{deliveries})"
    #    end
    #    consumer.run!
    #
    # 2. With auto-run (returns Thread):
    #    thread = JetstreamBridge.subscribe(run: true) do |event, subject, deliveries|
    #      puts "Received: #{event['event_type']}"
    #    end
    #    thread.join # Wait for consumer to finish
    #
    # 3. With a handler object:
    #    handler = ->(event, subject, deliveries) { puts event['event_type'] }
    #    consumer = JetstreamBridge.subscribe(handler)
    #    consumer.run!
    #
    # @param handler [Proc, #call, nil] Message handler (optional if block given)
    # @param run [Boolean] If true, automatically runs consumer in a background thread
    # @param durable_name [String, nil] Optional durable consumer name override
    # @param batch_size [Integer, nil] Optional batch size override
    # @yield [event, subject, deliveries] Yields event hash, NATS subject, and delivery count to block
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
