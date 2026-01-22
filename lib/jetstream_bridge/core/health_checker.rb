# frozen_string_literal: true

require_relative 'logging'

module JetstreamBridge
  # Health checking service for JetStream Bridge
  #
  # Responsible for:
  # - Connection health monitoring
  # - Stream information gathering
  # - Performance metrics collection
  # - Rate limiting health check requests
  class HealthChecker
    # Rate limit window for uncached health checks in seconds
    RATE_LIMIT_WINDOW = 5

    def initialize(connection_manager, config)
      @connection_manager = connection_manager
      @config = config
      @rate_limiter_mutex = Mutex.new
      @last_uncached_check = nil
    end

    # Perform comprehensive health check
    #
    # @param skip_cache [Boolean] Force fresh health check (rate limited)
    # @return [Hash] Health status including connection, stream, performance, config, and version
    def check(skip_cache: false)
      enforce_rate_limit! if skip_cache

      start_time = Time.now

      connection_health = fetch_connection_health(skip_cache)
      stream_info = fetch_stream_info if should_fetch_stream_info?(connection_health)
      rtt_ms = measure_nats_rtt if should_measure_rtt?(connection_health)

      health_check_duration_ms = ((Time.now - start_time) * 1000).round(2)

      {
        healthy: overall_healthy?(connection_health, stream_info),
        connection: connection_health,
        stream: stream_info || default_stream_info,
        performance: {
          nats_rtt_ms: rtt_ms,
          health_check_duration_ms: health_check_duration_ms
        },
        config: config_summary,
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

    private

    def enforce_rate_limit!
      @rate_limiter_mutex.synchronize do
        now = Time.now
        if @last_uncached_check
          time_since = now - @last_uncached_check
          if time_since < RATE_LIMIT_WINDOW
            raise HealthCheckFailedError,
                  "Health check rate limit exceeded. Please wait #{(RATE_LIMIT_WINDOW - time_since).ceil} second(s)"
          end
        end
        @last_uncached_check = now
      end
    end

    def fetch_connection_health(skip_cache)
      if @connection_manager
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
    end

    def should_fetch_stream_info?(connection_health)
      connection_health[:connected] && !@config.disable_js_api
    end

    def should_measure_rtt?(connection_health)
      connection_health[:connected] && !@config.disable_js_api
    end

    def overall_healthy?(connection_health, stream_info)
      return false unless connection_health[:connected]
      return true if @config.disable_js_api

      stream_info&.fetch(:exists, false) || false
    end

    def default_stream_info
      { exists: nil, name: @config.stream_name }
    end

    def config_summary
      {
        app_name: @config.app_name,
        destination_app: @config.destination_app,
        use_outbox: @config.use_outbox,
        use_inbox: @config.use_inbox,
        use_dlq: @config.use_dlq,
        disable_js_api: @config.disable_js_api
      }
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
        tag: 'JetstreamBridge::HealthChecker'
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
