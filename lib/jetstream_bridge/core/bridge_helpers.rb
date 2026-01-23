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
        return skipped_stream_info unless config.auto_provision

        # Ensure we have an active connection before querying stream info
        connect_if_needed!

        jts = Connection.jetstream
        raise ConnectionNotEstablishedError, 'NATS connection not established' unless jts

        stream_info_payload(jts.stream_info(config.stream_name))
      rescue StandardError => e
        stream_error_payload(e)
      end

      def measure_nats_rtt
        nc = Connection.nc
        return nil unless nc

        # Prefer native RTT API when available (e.g., new NATS clients)
        if nc.respond_to?(:rtt)
          rtt_value = normalize_ms(nc.rtt)
          return rtt_value if rtt_value
        end

        # Fallback for clients without #rtt (nats-pure): measure ping/pong via flush
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
        # Heuristic: sub-1 values are likely seconds; convert them to ms for reporting
        ms = numeric < 1 ? numeric * 1000 : numeric
        ms.round(2)
      end

      def assign_config_option!(cfg, key, val)
        setter = :"#{key}="
        raise ArgumentError, "Unknown configuration option: #{key}" unless cfg.respond_to?(setter)

        cfg.public_send(setter, val)
      end

      def stream_info_payload(info)
        config_data = info.config
        state_data = info.state

        {
          exists: true,
          name: config.stream_name,
          subjects: extract_field(config_data, :subjects),
          messages: extract_field(state_data, :messages)
        }
      end

      def extract_field(data, key)
        data.respond_to?(key) ? data.public_send(key) : data[key]
      end

      def stream_error_payload(error)
        {
          exists: false,
          name: config.stream_name,
          error: "#{error.class}: #{error.message}"
        }
      end

      def skipped_stream_info
        {
          exists: nil,
          name: config.stream_name,
          skipped: true,
          reason: 'auto_provision=false (skip $JS.API.STREAM.INFO)'
        }
      end
    end
  end
end
