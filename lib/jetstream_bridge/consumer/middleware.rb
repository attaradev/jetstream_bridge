# frozen_string_literal: true

module JetstreamBridge
  class Consumer; end

  # Middleware classes for Consumer
  module ConsumerMiddleware
    # Middleware chain for consumer message processing
    #
    # Allows you to wrap message processing with cross-cutting concerns like
    # logging, error handling, metrics, tracing, etc.
    #
    # @example Using middleware
    #   consumer = JetstreamBridge::Consumer::Consumer.new(handler)
    #   consumer.use(JetstreamBridge::Consumer::LoggingMiddleware.new)
    #   consumer.use(JetstreamBridge::Consumer::MetricsMiddleware.new)
    #   consumer.run!
    #
    class MiddlewareChain
      def initialize
        @middlewares = []
      end

      # Add a middleware to the chain
      #
      # @param middleware [Object] Middleware that responds to #call(event, &block)
      # @return [self]
      def use(middleware)
        @middlewares << middleware
        self
      end

      # Execute the middleware chain
      #
      # @param event [Models::Event] The event to process
      # @yield Final handler to call after all middleware
      # @return [void]
      def call(event, &final_handler)
        chain = @middlewares.reverse.reduce(final_handler) do |next_middleware, middleware|
          lambda do |evt|
            middleware.call(evt) { next_middleware.call(evt) }
          end
        end
        chain.call(event)
      end
    end

    # Logging middleware for consumer message processing
    #
    # @example
    #   consumer.use(JetstreamBridge::Consumer::LoggingMiddleware.new)
    #
    class LoggingMiddleware
      def call(event)
        start = Time.now
        Logging.info("Processing event #{event.event_id} (#{event.type})", tag: 'Consumer')
        yield
        duration = Time.now - start
        Logging.info("Completed event #{event.event_id} in #{duration.round(3)}s", tag: 'Consumer')
      rescue StandardError => e
        Logging.error("Failed event #{event.event_id}: #{e.message}", tag: 'Consumer')
        raise
      end
    end

    # Error handling middleware with configurable retry logic
    #
    # @example
    #   consumer.use(JetstreamBridge::Consumer::ErrorHandlingMiddleware.new(
    #     on_error: ->(event, error) { Sentry.capture_exception(error) }
    #   ))
    #
    class ErrorHandlingMiddleware
      def initialize(on_error: nil)
        @on_error = on_error
      end

      def call(event)
        yield
      rescue StandardError => e
        @on_error&.call(event, e)
        raise
      end
    end

    # Metrics middleware for tracking event processing
    #
    # @example
    #   consumer.use(JetstreamBridge::Consumer::MetricsMiddleware.new(
    #     on_success: ->(event, duration) { StatsD.timing("event.process", duration) },
    #     on_failure: ->(event, error) { StatsD.increment("event.failed") }
    #   ))
    #
    class MetricsMiddleware
      def initialize(on_success: nil, on_failure: nil)
        @on_success = on_success
        @on_failure = on_failure
      end

      def call(event)
        start = Time.now
        yield
        duration = Time.now - start
        @on_success&.call(event, duration)
      rescue StandardError => e
        @on_failure&.call(event, e)
        raise
      end
    end

    # Tracing middleware for distributed tracing
    #
    # @example
    #   consumer.use(JetstreamBridge::Consumer::TracingMiddleware.new)
    #
    class TracingMiddleware
      def call(event)
        trace_id = event.metadata.trace_id || event.trace_id

        if defined?(ActiveSupport::CurrentAttributes)
          # Set trace context if using Rails CurrentAttributes
          previous_trace_id = Current.trace_id if defined?(Current)
          Current.trace_id = trace_id if defined?(Current)
        end

        yield
      ensure
        Current.trace_id = previous_trace_id if defined?(Current) && defined?(previous_trace_id)
      end
    end

    # Timeout middleware to prevent long-running handlers
    #
    # @example
    #   consumer.use(JetstreamBridge::Consumer::TimeoutMiddleware.new(timeout: 30))
    #
    class TimeoutMiddleware
      def initialize(timeout: 30)
        @timeout = timeout
      end

      def call(event, &)
        require 'timeout'
        Timeout.timeout(@timeout, &)
      rescue Timeout::Error
        raise ConsumerError.new(
          "Event processing timeout after #{@timeout}s",
          event_id: event.event_id,
          deliveries: event.deliveries
        )
      end
    end
  end
end
