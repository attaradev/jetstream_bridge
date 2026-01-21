# frozen_string_literal: true

require 'oj'
require 'securerandom'
require_relative '../core/connection'
require_relative '../core/duration'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative 'message_processor'
require_relative 'subscription_manager'
require_relative 'inbox/inbox_processor'

module JetstreamBridge
  # Subscribes to destination subject and processes messages via a pull durable consumer.
  #
  # The Consumer provides reliable message processing with features like:
  # - Durable pull-based subscriptions with configurable batch sizes
  # - Optional idempotent inbox pattern for exactly-once processing
  # - Middleware support for cross-cutting concerns (logging, metrics, tracing)
  # - Automatic reconnection and error recovery
  # - Graceful shutdown with message draining
  #
  # @example Basic consumer
  #   consumer = JetstreamBridge::Consumer.new do |event|
  #     puts "Received: #{event.type} - #{event.payload.to_h}"
  #     # Process event...
  #   end
  #   consumer.run!
  #
  # @example Consumer with middleware
  #   consumer = JetstreamBridge::Consumer.new(handler)
  #   consumer.use(JetstreamBridge::Consumer::LoggingMiddleware.new)
  #   consumer.use(JetstreamBridge::Consumer::MetricsMiddleware.new)
  #   consumer.run!
  #
  # @example Using convenience method
  #   JetstreamBridge.subscribe do |event|
  #     ProcessEventJob.perform_later(event.to_h)
  #   end.run!
  #
  class Consumer
    # Default number of messages to fetch in each batch
    DEFAULT_BATCH_SIZE    = 25
    # Timeout for fetching messages from NATS (seconds)
    FETCH_TIMEOUT_SECS    = 5
    # Initial sleep duration when no messages available (seconds)
    IDLE_SLEEP_SECS       = 0.05
    # Maximum sleep duration during idle periods (seconds)
    MAX_IDLE_BACKOFF_SECS = 1.0

    # Alias middleware classes for easier access
    MiddlewareChain = ConsumerMiddleware::MiddlewareChain
    LoggingMiddleware = ConsumerMiddleware::LoggingMiddleware
    ErrorHandlingMiddleware = ConsumerMiddleware::ErrorHandlingMiddleware
    MetricsMiddleware = ConsumerMiddleware::MetricsMiddleware
    TracingMiddleware = ConsumerMiddleware::TracingMiddleware
    TimeoutMiddleware = ConsumerMiddleware::TimeoutMiddleware

    # @return [String] Durable consumer name
    attr_reader :durable
    # @return [Integer] Batch size for message fetching
    attr_reader :batch_size
    # @return [MiddlewareChain] Middleware chain for processing
    attr_reader :middleware_chain

    # Initialize a new Consumer instance.
    #
    # @param handler [Proc, #call, nil] Message handler that processes events.
    #   Must respond to #call(event) or #call(event, subject, deliveries).
    # @param durable_name [String, nil] Optional durable consumer name override.
    #   Defaults to config.durable_name.
    # @param batch_size [Integer, nil] Number of messages to fetch per batch.
    #   Defaults to DEFAULT_BATCH_SIZE (25).
    # @yield [event] Optional block as handler. Receives Models::Event object.
    #
    # @raise [ArgumentError] If neither handler nor block provided
    # @raise [ArgumentError] If destination_app not configured
    # @raise [ConnectionError] If unable to connect to NATS
    #
    # @example With proc handler
    #   handler = ->(event) { puts "Received: #{event.type}" }
    #   consumer = JetstreamBridge::Consumer.new(handler)
    #
    # @example With block
    #   consumer = JetstreamBridge::Consumer.new do |event|
    #     UserEventHandler.process(event)
    #   end
    #
    # @example With custom configuration
    #   consumer = JetstreamBridge::Consumer.new(
    #     handler,
    #     durable_name: "my-consumer",
    #     batch_size: 10
    #   )
    #
    def initialize(handler = nil, durable_name: nil, batch_size: nil, &block)
      @handler = handler || block
      raise ArgumentError, 'handler or block required' unless @handler

      @batch_size    = Integer(batch_size || DEFAULT_BATCH_SIZE)
      @durable       = durable_name || JetstreamBridge.config.durable_name
      @idle_backoff  = IDLE_SLEEP_SECS
      @reconnect_attempts = 0
      @running = true
      @shutdown_requested = false
      @start_time    = Time.now
      @iterations    = 0
      @last_health_check = Time.now
      # Use existing connection (should already be established)
      @jts = Connection.jetstream
      raise ConnectionError, 'JetStream connection not available. Call JetstreamBridge.startup! first.' unless @jts

      @middleware_chain = MiddlewareChain.new

      ensure_destination_app_configured!

      @sub_mgr = SubscriptionManager.new(@jts, @durable, JetstreamBridge.config)
      @processor  = MessageProcessor.new(@jts, @handler, middleware_chain: @middleware_chain)
      @inbox_proc = InboxProcessor.new(@processor) if JetstreamBridge.config.use_inbox

      ensure_subscription!
      setup_signal_handlers
    end

    # Add middleware to the processing chain.
    #
    # Middleware is executed in the order it's added. Each middleware must respond
    # to #call(event, &block) and yield to continue the chain.
    #
    # @param middleware [Object] Middleware that responds to #call(event, &block).
    #   Must yield to continue processing.
    # @return [self] Returns self for method chaining
    #
    # @example Adding multiple middleware
    #   consumer = JetstreamBridge.subscribe { |event| process(event) }
    #   consumer.use(JetstreamBridge::Consumer::LoggingMiddleware.new)
    #   consumer.use(JetstreamBridge::Consumer::MetricsMiddleware.new)
    #   consumer.use(JetstreamBridge::Consumer::TimeoutMiddleware.new(timeout: 30))
    #   consumer.run!
    #
    # @example Custom middleware
    #   class MyMiddleware
    #     def call(event)
    #       puts "Before: #{event.type}"
    #       yield
    #       puts "After: #{event.type}"
    #     end
    #   end
    #   consumer.use(MyMiddleware.new)
    #
    def use(middleware)
      @middleware_chain.use(middleware)
      self
    end

    # Start the consumer and process messages in a blocking loop.
    #
    # This method blocks the current thread and continuously fetches and processes
    # messages until stop! is called or a signal is received (INT/TERM).
    #
    # The consumer will:
    # - Fetch messages in batches (configurable batch_size)
    # - Process each message through the middleware chain
    # - Handle errors and reconnection automatically
    # - Implement exponential backoff during idle periods
    # - Drain in-flight messages during graceful shutdown
    #
    # @return [void]
    #
    # @example Basic usage
    #   consumer = JetstreamBridge::Consumer.new { |event| process(event) }
    #   consumer.run!  # Blocks here
    #
    # @example In a Rake task
    #   namespace :jetstream do
    #     task consume: :environment do
    #       consumer = JetstreamBridge.subscribe { |event| handle(event) }
    #       trap("TERM") { consumer.stop! }
    #       consumer.run!
    #     end
    #   end
    #
    # @example With error handling
    #   consumer = JetstreamBridge::Consumer.new do |event|
    #     process(event)
    #   rescue RecoverableError => e
    #     raise  # Let NATS retry
    #   rescue UnrecoverableError => e
    #     logger.error(e)  # Log but don't raise (moves to DLQ if configured)
    #   end
    #   consumer.run!
    #
    def run!
      Logging.info(
        "Consumer #{@durable} started (batch=#{@batch_size}, dest=#{JetstreamBridge.config.destination_subject})…",
        tag: 'JetstreamBridge::Consumer'
      )
      while @running
        processed = process_batch
        idle_sleep(processed)

        @iterations += 1

        # Periodic health checks every 10 minutes (600 seconds)
        perform_health_check_if_due
      end

      # Drain in-flight messages before exiting
      drain_inflight_messages if @shutdown_requested
      Logging.info("Consumer #{@durable} stopped gracefully", tag: 'JetstreamBridge::Consumer')
    end

    # Stop the consumer gracefully and drain in-flight messages.
    #
    # This method signals the consumer to stop processing new messages and drain
    # any messages that are currently being processed. It's safe to call from
    # signal handlers or other threads.
    #
    # The consumer will:
    # - Stop fetching new messages
    # - Complete processing of in-flight messages
    # - Drain pending messages (up to 5 batches)
    # - Close the subscription cleanly
    #
    # @return [void]
    #
    # @example In signal handler
    #   consumer = JetstreamBridge::Consumer.new { |event| process(event) }
    #   trap("TERM") { consumer.stop! }
    #   consumer.run!
    #
    # @example Manual control
    #   consumer = JetstreamBridge::Consumer.new { |event| process(event) }
    #   Thread.new { consumer.run! }
    #   sleep 10
    #   consumer.stop!  # Stop after 10 seconds
    #
    def stop!
      @shutdown_requested = true
      @running = false
      Logging.info("Consumer #{@durable} shutdown requested", tag: 'JetstreamBridge::Consumer')
    end

    private

    def ensure_destination_app_configured!
      return unless JetstreamBridge.config.destination_app.to_s.empty?

      raise ArgumentError, 'destination_app must be configured'
    end

    def ensure_subscription!
      @sub_mgr.ensure_consumer! unless JetstreamBridge.config.disable_js_api
      @psub = @sub_mgr.subscribe!
    end

    # Returns number of messages processed; 0 on timeout/idle or after recovery.
    def process_batch
      msgs = fetch_messages
      return 0 if msgs.nil? || msgs.empty?

      msgs.sum { |m| process_one(m) }
    rescue NATS::Timeout, NATS::IO::Timeout
      0
    rescue NATS::JetStream::Error => e
      handle_js_error(e)
    rescue StandardError => e
      Logging.error("Unexpected process_batch error: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      0
    end

    # --- helpers ---

    def fetch_messages
      @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
    end

    def process_one(msg)
      if @inbox_proc
        @inbox_proc.process(msg) ? 1 : 0
      else
        @processor.handle_message(msg)
        1
      end
    rescue StandardError => e
      # Safety: never let a single bad message kill the batch loop.
      Logging.error("Message processing crashed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      safe_nak_message(msg)
      0
    end

    def handle_js_error(error)
      if recoverable_consumer_error?(error)
        # Increment reconnect attempts and calculate exponential backoff
        @reconnect_attempts += 1
        backoff_secs = calculate_reconnect_backoff(@reconnect_attempts)

        Logging.warn(
          "Recovering subscription after error (attempt #{@reconnect_attempts}): " \
          "#{error.class} #{error.message}, waiting #{backoff_secs}s",
          tag: 'JetstreamBridge::Consumer'
        )

        sleep(backoff_secs)
        ensure_subscription!

        # Reset counter on successful reconnection
        @reconnect_attempts = 0
      else
        Logging.error("Fetch failed (non-recoverable): #{error.class} #{error.message}", tag: 'JetstreamBridge::Consumer')
      end
      0
    end

    def calculate_reconnect_backoff(attempt)
      # Exponential backoff: 0.1s, 0.2s, 0.4s, 0.8s, 1.6s, ... up to 30s max
      base_delay = 0.1
      max_delay = 30.0
      [base_delay * (2**(attempt - 1)), max_delay].min
    end

    def recoverable_consumer_error?(error)
      msg = error.message.to_s
      code = js_err_code(msg)
      # Heuristics: consumer/stream missing, no responders, or common 404-ish cases
      msg =~ /consumer.*(not\s+found|deleted)/i ||
        msg =~ /no\s+responders/i ||
        msg =~ /stream.*not\s+found/i ||
        code == 404
    end

    def js_err_code(message)
      m = message.match(/err_code=(\d{3,5})/)
      m ? m[1].to_i : nil
    end

    def idle_sleep(processed)
      if processed.zero?
        # exponential-ish backoff with a tiny jitter to avoid sync across workers
        @idle_backoff = [@idle_backoff * 1.5, MAX_IDLE_BACKOFF_SECS].min
        sleep(@idle_backoff + (rand * 0.01))
      else
        @idle_backoff = IDLE_SLEEP_SECS
      end
    end

    def setup_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          Logging.info("Received #{sig}, stopping consumer...", tag: 'JetstreamBridge::Consumer')
          stop!
        end
      end
    rescue ArgumentError => e
      # Signal handlers may not be available in all environments (e.g., threads)
      Logging.debug("Could not set up signal handlers: #{e.message}", tag: 'JetstreamBridge::Consumer')
    end

    def perform_health_check_if_due
      now = Time.now
      time_since_check = now - @last_health_check

      return unless time_since_check >= 600 # 10 minutes

      @last_health_check = now
      uptime = now - @start_time
      memory_mb = memory_usage_mb

      Logging.info(
        "Consumer health: iterations=#{@iterations}, " \
        "memory=#{memory_mb}MB, uptime=#{uptime.round}s",
        tag: 'JetstreamBridge::Consumer'
      )

      # Warn if memory usage is high (over 1GB)
      if memory_mb > 1000
        Logging.warn(
          "High memory usage detected: #{memory_mb}MB",
          tag: 'JetstreamBridge::Consumer'
        )
      end

      # Suggest GC if heap is growing significantly
      suggest_gc_if_needed
    rescue StandardError => e
      Logging.debug(
        "Health check failed: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def memory_usage_mb
      # Get memory usage from OS (works on Linux/macOS)
      rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
      rss_kb / 1024.0
    rescue StandardError
      0.0
    end

    def suggest_gc_if_needed
      return unless defined?(GC) && GC.respond_to?(:stat)

      stats = GC.stat
      heap_live_slots = stats[:heap_live_slots] || stats['heap_live_slots'] || 0

      threshold = 200_000
      return if heap_live_slots < threshold || @gc_warning_logged

      @gc_warning_logged = true
      Logging.warn(
        "High heap object count detected (#{heap_live_slots}); consider profiling or manual GC in the host app",
        tag: 'JetstreamBridge::Consumer'
      )
    rescue StandardError => e
      Logging.debug(
        "GC check failed: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def drain_inflight_messages
      return unless @psub

      Logging.info('Draining in-flight messages...', tag: 'JetstreamBridge::Consumer')
      # Process any pending messages with a short timeout
      5.times do
        msgs = @psub.fetch(@batch_size, timeout: 1)
        break if msgs.nil? || msgs.empty?

        msgs.each { |m| process_one(m) }
      rescue NATS::Timeout, NATS::IO::Timeout
        break
      rescue StandardError => e
        Logging.warn("Error draining messages: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
        break
      end
      Logging.info('Drain complete', tag: 'JetstreamBridge::Consumer')
    rescue StandardError => e
      Logging.error("Drain failed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
    end

    def safe_nak_message(msg)
      return unless msg.respond_to?(:nak)

      msg.nak
    rescue StandardError => e
      Logging.error("Failed to NAK message after crash: #{e.class} #{e.message}",
                    tag: 'JetstreamBridge::Consumer')
    end
  end
end
