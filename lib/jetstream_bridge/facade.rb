# frozen_string_literal: true

require_relative 'core/config'
require_relative 'core/connection_manager'
require_relative 'core/logging'
require_relative 'factories'
require_relative 'topology/topology'

module JetstreamBridge
  # Facade that coordinates all subsystems
  #
  # Responsible for:
  # - Managing configuration
  # - Managing connection lifecycle
  # - Creating publishers and consumers via factories
  # - Health checking
  class Facade
    attr_reader :config

    def initialize
      @config = Config.new
      @connection_manager = nil
      @publisher_factory = nil
      @consumer_factory = nil
      @health_check_mutex = Mutex.new
      @last_uncached_health_check = nil
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
    def publish(event_type:, payload:, **options)
      connect_if_needed!
      publisher_factory.create.publish(event_type: event_type, payload: payload, **options)
    end

    # Publish a complete event envelope (advanced)
    #
    # @param envelope [Hash] Complete event envelope
    # @param subject [String, nil] Optional subject override
    # @return [Models::PublishResult] Result object
    def publish_envelope(envelope, subject: nil)
      connect_if_needed!
      publisher_factory.create.publish_envelope(envelope, subject: subject)
    end

    # Subscribe to events
    #
    # @param handler [Proc, #call, nil] Message handler
    # @param options [Hash] Consumer options
    # @yield [event] Optional block as handler
    # @return [Consumer] Consumer instance
    def subscribe(handler = nil, **options, &block)
      connect_if_needed!
      consumer_factory.create(handler || block, **options)
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
      # Rate limit uncached requests
      enforce_health_check_rate_limit! if skip_cache

      start_time = Time.now

      # Connection health
      connection_health = if @connection_manager
                            @connection_manager.health_check(skip_cache: skip_cache)
                          else
                            {
                              connected: false,
                              state: :disconnected,
                              connected_at: nil,
                              last_error: 'Not connected',
                              last_error_at: nil
                            }
                          end

      # Stream info
      stream_info = fetch_stream_info if connection_health[:connected] && !@config.disable_js_api

      # RTT measurement
      rtt_ms = measure_nats_rtt if connection_health[:connected] && !@config.disable_js_api

      health_check_duration_ms = ((Time.now - start_time) * 1000).round(2)

      {
        healthy: connection_health[:connected] && (@config.disable_js_api ? true : stream_info&.fetch(:exists, false)),
        connection: connection_health,
        stream: stream_info || { exists: nil, name: @config.stream_name },
        performance: {
          nats_rtt_ms: rtt_ms,
          health_check_duration_ms: health_check_duration_ms
        },
        config: {
          env: @config.env,
          app_name: @config.app_name,
          destination_app: @config.destination_app,
          use_outbox: @config.use_outbox,
          use_inbox: @config.use_inbox,
          use_dlq: @config.use_dlq,
          disable_js_api: @config.disable_js_api
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
      fetch_stream_info
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

    def publisher_factory
      @publisher_factory ||= begin
        ensure_connection_manager!
        PublisherFactory.new(@connection_manager, @config)
      end
    end

    def consumer_factory
      @consumer_factory ||= begin
        ensure_connection_manager!
        ConsumerFactory.new(@connection_manager, @config)
      end
    end

    def enforce_health_check_rate_limit!
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
      return nil unless @connection_manager

      jts = @connection_manager.jetstream
      return nil unless jts

      info = jts.stream_info(@config.stream_name)

      # Handle both object-style and hash-style access for compatibility
      config_data = info.config
      state_data = info.state
      subjects = config_data.respond_to?(:subjects) ? config_data.subjects : config_data[:subjects]
      messages = state_data.respond_to?(:messages) ? state_data.messages : state_data[:messages]

      {
        exists: true,
        name: @config.stream_name,
        subjects: subjects,
        messages: messages
      }
    rescue StandardError => e
      {
        exists: false,
        name: @config.stream_name,
        error: "#{e.class}: #{e.message}"
      }
    end

    def measure_nats_rtt
      return nil unless @connection_manager

      nc = @connection_manager.nats_client
      return nil unless nc

      # Prefer native RTT API when available
      if nc.respond_to?(:rtt)
        rtt_value = normalize_ms(nc.rtt)
        return rtt_value if rtt_value
      end

      # Fallback: measure ping/pong via flush
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      nc.flush(1)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      normalize_ms(duration)
    rescue StandardError => e
      Logging.warn(
        "Failed to measure NATS RTT: #{e.class} #{e.message}",
        tag: 'JetstreamBridge'
      )
      nil
    end

    def normalize_ms(value)
      return nil if value.nil?
      return nil unless value.respond_to?(:to_f)

      numeric = value.to_f
      # Heuristic: sub-1 values are likely seconds; convert them to ms
      ms = numeric < 1 ? numeric * 1000 : numeric
      ms.round(2)
    end
  end
end
