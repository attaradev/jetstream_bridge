# frozen_string_literal: true

require_relative 'logging'
require_relative 'connection'

module JetstreamBridge
  module Core
    # Internal helper methods extracted from the main JetstreamBridge module
    # to keep the public API surface focused.
    module BridgeHelpers
      private

      # Ensure connection is established before use
      # Automatically connects on first use if not already connected
      # Thread-safe and idempotent
      def connect_if_needed!
        return if @connection_initialized

        startup!
      end

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
        # Ensure we have an active connection before querying stream info
        connect_if_needed!

        jts = Connection.jetstream
        raise ConnectionNotEstablishedError, 'NATS connection not established' unless jts

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

      def assign_config_option!(cfg, key, val)
        setter = :"#{key}="
        raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

        cfg.public_send(setter, val)
      end
    end
  end
end
