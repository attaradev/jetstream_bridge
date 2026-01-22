# frozen_string_literal: true

require_relative '../core/logging'

module JetstreamBridge
  # Health monitoring for Consumer instances
  #
  # Responsible for:
  # - Periodic health checks
  # - Memory usage monitoring
  # - Heap object tracking
  # - GC recommendations
  class ConsumerHealthMonitor
    # Health check interval in seconds (10 minutes)
    HEALTH_CHECK_INTERVAL = 600
    # Memory warning threshold in MB
    MEMORY_WARNING_THRESHOLD_MB = 1000
    # Heap object count warning threshold
    HEAP_OBJECT_WARNING_THRESHOLD = 200_000

    def initialize(consumer_name)
      @consumer_name = consumer_name
      @start_time = Time.now
      @last_check = Time.now
      @iterations = 0
      @gc_warning_logged = false
    end

    # Increment iteration counter
    def increment_iterations
      @iterations += 1
    end

    # Check if health check is due and perform if needed
    #
    # @return [Boolean] true if check was performed
    def check_health_if_due
      now = Time.now
      time_since_check = now - @last_check

      return false unless time_since_check >= HEALTH_CHECK_INTERVAL

      perform_check(now)
      true
    end

    private

    def perform_check(now)
      @last_check = now
      uptime = now - @start_time
      memory_mb = memory_usage_mb

      Logging.info(
        "Consumer health: iterations=#{@iterations}, " \
        "memory=#{memory_mb}MB, uptime=#{uptime.round}s",
        tag: "JetstreamBridge::Consumer(#{@consumer_name})"
      )

      warn_if_high_memory(memory_mb)
      suggest_gc_if_needed
    rescue StandardError => e
      Logging.debug(
        "Health check failed: #{e.class} #{e.message}",
        tag: "JetstreamBridge::Consumer(#{@consumer_name})"
      )
    end

    def memory_usage_mb
      # Get memory usage from OS (works on Linux/macOS)
      rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
      rss_kb / 1024.0
    rescue StandardError
      0.0
    end

    def warn_if_high_memory(memory_mb)
      return unless memory_mb > MEMORY_WARNING_THRESHOLD_MB

      Logging.warn(
        "High memory usage detected: #{memory_mb}MB",
        tag: "JetstreamBridge::Consumer(#{@consumer_name})"
      )
    end

    def suggest_gc_if_needed
      return unless defined?(GC) && GC.respond_to?(:stat)

      stats = GC.stat
      heap_live_slots = stats[:heap_live_slots] || stats['heap_live_slots'] || 0

      return if heap_live_slots < HEAP_OBJECT_WARNING_THRESHOLD || @gc_warning_logged

      @gc_warning_logged = true
      Logging.warn(
        "High heap object count detected (#{heap_live_slots}); " \
        'consider profiling or manual GC in the host app',
        tag: "JetstreamBridge::Consumer(#{@consumer_name})"
      )
    rescue StandardError => e
      Logging.debug(
        "GC check failed: #{e.class} #{e.message}",
        tag: "JetstreamBridge::Consumer(#{@consumer_name})"
      )
    end
  end
end
