# frozen_string_literal: true

module JetstreamBridge
  class Consumer
    # Tracks processing counters and backoff state.
    class ProcessingState
      attr_accessor :idle_backoff, :iterations

      def initialize(idle_backoff:, iterations: 0)
        @idle_backoff = idle_backoff
        @iterations = iterations
      end
    end

    # Tracks lifecycle flags and timing for the consumer.
    class LifecycleState
      attr_accessor :running, :shutdown_requested, :signal_received, :signal_logged
      attr_reader :start_time

      def initialize(start_time: Time.now)
        @running = true
        @shutdown_requested = false
        @signal_received = nil
        @signal_logged = false
        @start_time = start_time
      end

      def stop!
        @shutdown_requested = true
        @running = false
      end

      def signal!(sig)
        @signal_received = sig
        stop!
      end

      def uptime(now = Time.now)
        now - @start_time
      end
    end

    # Tracks reconnection attempts and health check timing.
    class ConnectionState
      attr_accessor :reconnect_attempts
      attr_reader :last_health_check

      def initialize(now: Time.now)
        @reconnect_attempts = 0
        @last_health_check = now
      end

      def mark_health_check(now = Time.now)
        @last_health_check = now
      end
    end
  end
end
