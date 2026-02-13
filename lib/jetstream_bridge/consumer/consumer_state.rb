# frozen_string_literal: true

module JetstreamBridge
  class Consumer
    # Tracks processing counters and idle-backoff state.
    class ProcessingState
      # @return [Float] Current idle backoff duration in seconds
      attr_accessor :idle_backoff
      # @return [Integer] Total number of processing loop iterations
      attr_accessor :iterations

      # @param idle_backoff [Float] Initial idle backoff duration (seconds)
      # @param iterations [Integer] Starting iteration count
      def initialize(idle_backoff:, iterations: 0)
        @idle_backoff = idle_backoff
        @iterations = iterations
      end
    end

    # Tracks lifecycle flags and timing for the consumer.
    class LifecycleState
      # @return [Boolean] Whether the consumer loop should keep running
      attr_accessor :running
      # @return [Boolean] Whether a graceful shutdown has been requested
      attr_accessor :shutdown_requested
      # @return [String, nil] Signal name that triggered shutdown (e.g. "INT")
      attr_accessor :signal_received
      # @return [Boolean] Whether the signal receipt has been logged
      attr_accessor :signal_logged
      # @return [Time] When the consumer started
      attr_reader :start_time

      # @param start_time [Time] Consumer start time (defaults to now)
      def initialize(start_time: Time.now)
        @running = true
        @shutdown_requested = false
        @signal_received = nil
        @signal_logged = false
        @start_time = start_time
      end

      # Request a graceful shutdown.
      #
      # @return [void]
      def stop!
        @shutdown_requested = true
        @running = false
      end

      # Record an OS signal and trigger shutdown.
      #
      # @param sig [String] Signal name (e.g. "INT", "TERM")
      # @return [void]
      def signal!(sig)
        @signal_received = sig
        stop!
      end

      # Calculate consumer uptime in seconds.
      #
      # @param now [Time] Current time
      # @return [Float] Uptime in seconds
      def uptime(now = Time.now)
        now - @start_time
      end
    end

    # Tracks reconnection attempts and health check timing.
    class ConnectionState
      # @return [Integer] Number of consecutive reconnection attempts
      attr_accessor :reconnect_attempts
      # @return [Time] When the last health check was performed
      attr_reader :last_health_check

      # @param now [Time] Initial health check timestamp
      def initialize(now: Time.now)
        @reconnect_attempts = 0
        @last_health_check = now
      end

      # Record that a health check was performed.
      #
      # @param now [Time] Timestamp of the health check
      # @return [void]
      def mark_health_check(now = Time.now)
        @last_health_check = now
      end
    end
  end
end
