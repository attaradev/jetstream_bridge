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
require_relative 'consumer_state'
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

    class << self
      def register_consumer_for_signals(consumer)
        signal_registry_mutex.synchronize do
          signal_consumers << consumer
          install_signal_handlers_once
        end
      end

      def unregister_consumer_for_signals(consumer)
        signal_registry_mutex.synchronize { signal_consumers.delete(consumer) }
      end

      def reset_signal_handlers!
        signal_registry_mutex.synchronize { signal_consumers.clear }
        @signal_handlers_installed = false
        @previous_signal_handlers = {}
      end

      private

      def signal_consumers
        @signal_consumers ||= []
      end

      def signal_registry_mutex
        @signal_registry_mutex ||= Mutex.new
      end

      def install_signal_handlers_once
        return if @signal_handlers_installed

        %w[INT TERM].each { |sig| install_signal_handler(sig) }
        @signal_handlers_installed = true
      end

      def install_signal_handler(sig)
        previous = nil
        handler = nil
        handler = proc do
          broadcast_signal(sig)
          invoke_previous_handler(previous, sig, handler)
        rescue StandardError
          # Trap contexts must stay minimal; swallow any unexpected errors
        end
        previous = Signal.trap(sig, &handler)
        previous_signal_handlers[sig] = previous
      rescue ArgumentError => e
        Logging.debug("Could not set up signal handlers: #{e.message}", tag: 'JetstreamBridge::Consumer')
      end

      def broadcast_signal(sig)
        consumers = nil
        signal_registry_mutex.synchronize { consumers = signal_consumers.dup }
        consumers.each do |consumer|
          next unless consumer.respond_to?(:lifecycle_state)

          consumer.lifecycle_state.signal!(sig)
        end
      rescue StandardError
        # Trap safety: never raise
      end

      def invoke_previous_handler(previous, sig, current_handler = nil)
        return if previous.nil? || previous == 'DEFAULT' || previous == 'SYSTEM_DEFAULT'
        return if previous == 'IGNORE'
        return if current_handler && previous.equal?(current_handler)

        previous.call(sig) if previous.respond_to?(:call)
      rescue StandardError
        # Never bubble from trap context
      end

      def previous_signal_handlers
        @previous_signal_handlers ||= {}
      end
    end

    # @return [String] Durable consumer name
    attr_reader :durable
    # @return [Integer] Batch size for message fetching
    attr_reader :batch_size
    # @return [MiddlewareChain] Middleware chain for processing
    attr_reader :middleware_chain
    # Expose grouped state objects for observability/testing
    attr_reader :processing_state, :lifecycle_state, :connection_state

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
      @processing_state = ProcessingState.new(idle_backoff: IDLE_SLEEP_SECS)
      @lifecycle_state = LifecycleState.new
      @connection_state = ConnectionState.new
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
      while @lifecycle_state.running
        # Check if signal was received and log it (safe from main loop)
        if @lifecycle_state.signal_received && !@lifecycle_state.signal_logged
          Logging.info("Received #{@lifecycle_state.signal_received}, stopping consumer...",
                       tag: 'JetstreamBridge::Consumer')
          @lifecycle_state.signal_logged = true
        end

        Logging.debug(
          "Fetching messages (iteration=#{@processing_state.iterations}, batch_size=#{@batch_size})...",
          tag: 'JetstreamBridge::Consumer'
        )
        processed = process_batch
        Logging.debug(
          "Processed #{processed} messages",
          tag: 'JetstreamBridge::Consumer'
        )
        idle_sleep(processed)

        @processing_state.iterations += 1

        # Periodic health checks every 10 minutes (600 seconds)
        perform_health_check_if_due
      end

      # Drain in-flight messages before exiting
      drain_inflight_messages if @lifecycle_state.shutdown_requested
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
      @lifecycle_state.stop!
      # Allow other consumers to continue receiving signals without stale references
      self.class.unregister_consumer_for_signals(self)
      Logging.info("Consumer #{@durable} shutdown requested", tag: 'JetstreamBridge::Consumer')
    end

    private

    def ensure_subscription!
      @sub_mgr.ensure_consumer!
      @psub = @sub_mgr.subscribe!
    end

    def ensure_destination_app_configured!
      # Use subject builder to enforce required components and align with existing validation messages.
      JetstreamBridge.config.destination_subject
    end

    # Returns number of messages processed; 0 on timeout/idle or after recovery.
    def process_batch
      Logging.debug('Calling fetch_messages...', tag: 'JetstreamBridge::Consumer')
      msgs = fetch_messages
      Logging.debug("Fetched #{msgs&.size || 0} messages", tag: 'JetstreamBridge::Consumer')
      return 0 if msgs.nil? || msgs.empty?

      msgs.sum { |m| process_one(m) }
    rescue NATS::Timeout, NATS::IO::Timeout => e
      Logging.debug("Fetch timeout: #{e.class}", tag: 'JetstreamBridge::Consumer')
      0
    rescue NATS::JetStream::Error => e
      Logging.error("JetStream error: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      handle_js_error(e)
    rescue StandardError => e
      Logging.error("Unexpected process_batch error: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      Logging.error("Backtrace: #{e.backtrace.first(5).join("\n")}", tag: 'JetstreamBridge::Consumer')
      0
    end

    # --- helpers ---

    def fetch_messages
      if JetstreamBridge.config.push_consumer?
        fetch_messages_push
      else
        fetch_messages_pull
      end
    end

    def fetch_messages_pull
      Logging.debug(
        "fetch_messages_pull called (@psub=#{@psub.class}, batch=#{@batch_size}, timeout=#{FETCH_TIMEOUT_SECS})",
        tag: 'JetstreamBridge::Consumer'
      )
      result = @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
      Logging.debug("fetch returned #{result&.size || 0} messages", tag: 'JetstreamBridge::Consumer')
      result
    rescue StandardError => e
      Logging.error("fetch_messages_pull error: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      Logging.error("Backtrace: #{e.backtrace.first(5).join("\n")}", tag: 'JetstreamBridge::Consumer')
      raise
    end

    def fetch_messages_push
      # For push consumers, collect messages from the subscription queue
      # Push subscriptions don't have a fetch method, so we use next_msg
      messages = []
      @batch_size.times do
        msg = @psub.next_msg(timeout: FETCH_TIMEOUT_SECS)
        messages << msg if msg
      rescue NATS::Timeout, NATS::IO::Timeout
        break
      end
      messages
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
        @connection_state.reconnect_attempts += 1
        backoff_secs = calculate_reconnect_backoff(@connection_state.reconnect_attempts)

        Logging.warn(
          "Recovering subscription after error (attempt #{@connection_state.reconnect_attempts}): " \
          "#{error.class} #{error.message}, waiting #{backoff_secs}s",
          tag: 'JetstreamBridge::Consumer'
        )

        # If this looks like a consumer-not-found error, try to auto-create it
        auto_create_consumer_on_error(error) if consumer_not_found_error?(error)

        sleep(backoff_secs)
        ensure_subscription!

        # Reset counter on successful reconnection
        @connection_state.reconnect_attempts = 0
      else
        Logging.error("Fetch failed (non-recoverable): #{error.class} #{error.message}", tag: 'JetstreamBridge::Consumer')
      end
      0
    end

    def consumer_not_found_error?(error)
      msg = error.message.to_s.downcase
      (msg.include?('consumer') && (msg.include?('not found') || msg.include?('does not exist'))) ||
        msg.include?('no responders')
    end

    def auto_create_consumer_on_error(_error)
      unless JetstreamBridge.config.auto_provision
        Logging.info(
          "Skipping consumer auto-creation (auto_provision=false) for #{@durable}",
          tag: 'JetstreamBridge::Consumer'
        )
        return
      end

      Logging.info(
        "Consumer not found error detected, attempting auto-creation for #{@durable}...",
        tag: 'JetstreamBridge::Consumer'
      )

      @sub_mgr.create_consumer_if_missing!
    rescue StandardError => e
      Logging.warn(
        "Auto-create consumer failed: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
      # Don't re-raise - let the normal recovery flow continue
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
        @processing_state.idle_backoff = [@processing_state.idle_backoff * 1.5, MAX_IDLE_BACKOFF_SECS].min
        sleep(@processing_state.idle_backoff + (rand * 0.01))
      else
        @processing_state.idle_backoff = IDLE_SLEEP_SECS
      end
    end

    def setup_signal_handlers
      self.class.register_consumer_for_signals(self)
    rescue StandardError => e
      Logging.debug("Could not set up signal handlers: #{e.message}", tag: 'JetstreamBridge::Consumer')
    end

    def perform_health_check_if_due
      now = Time.now
      time_since_check = now - @connection_state.last_health_check

      return unless time_since_check >= 600 # 10 minutes

      @connection_state.mark_health_check(now)
      uptime = @lifecycle_state.uptime(now)
      memory_mb = memory_usage_mb

      Logging.info(
        "Consumer health: iterations=#{@processing_state.iterations}, " \
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
      # Suggest GC if heap has many live slots (Ruby-specific optimization)
      return unless defined?(GC) && GC.respond_to?(:stat)

      stats = GC.stat
      heap_live_slots = stats[:heap_live_slots] || stats['heap_live_slots'] || 0

      # Suggest GC if we have over 100k live objects
      GC.start if heap_live_slots > 100_000
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
        msgs = if JetstreamBridge.config.push_consumer?
                 drain_messages_push
               else
                 @psub.fetch(@batch_size, timeout: 1)
               end
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

    def drain_messages_push
      # For push consumers during drain, collect messages with a shorter timeout
      messages = []
      @batch_size.times do
        msg = @psub.next_msg(timeout: 1)
        messages << msg if msg
      rescue NATS::Timeout, NATS::IO::Timeout
        break
      end
      messages
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
