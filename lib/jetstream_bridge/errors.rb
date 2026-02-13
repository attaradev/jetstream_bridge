# frozen_string_literal: true

module JetstreamBridge
  # Base error for all JetStream Bridge errors.
  #
  # Every error carries an optional +context+ hash for structured diagnostics.
  class Error < StandardError
    # @return [Hash] Structured context for diagnostics
    attr_reader :context

    # @param message [String, nil] Human-readable error message
    # @param context [Hash] Arbitrary diagnostic context (frozen on assignment)
    def initialize(message = nil, context: {})
      super(message)
      @context = context.freeze
    end
  end

  # Raised when configuration values are invalid or inconsistent.
  class ConfigurationError < Error; end

  # Raised when a NATS subject contains invalid characters.
  class InvalidSubjectError < ConfigurationError; end

  # Raised when a required configuration value is missing.
  class MissingConfigurationError < ConfigurationError; end

  # Raised when a NATS connection cannot be established or is lost.
  class ConnectionError < Error; end

  # Raised when an operation requires a connection that has not been established.
  class ConnectionNotEstablishedError < ConnectionError; end

  # Raised when a health check fails or is rate-limited.
  class HealthCheckFailedError < ConnectionError; end

  # Raised when an event fails to publish.
  class PublishError < Error
    # @return [String, nil] Event ID that failed to publish
    attr_reader :event_id
    # @return [String, nil] NATS subject the publish was attempted on
    attr_reader :subject

    # @param message [String, nil] Human-readable error message
    # @param event_id [String, nil] The event ID
    # @param subject [String, nil] The NATS subject
    # @param context [Hash] Additional diagnostic context
    def initialize(message = nil, event_id: nil, subject: nil, context: {})
      @event_id = event_id
      @subject = subject
      super(message, context: context.merge(event_id: event_id, subject: subject).compact)
    end
  end

  # Raised when a publish operation fails after retries.
  class PublishFailedError < PublishError; end

  # Raised when the outbox persistence layer encounters an error.
  class OutboxError < PublishError; end

  # Raised when a batch publish has one or more failures.
  class BatchPublishError < PublishError
    # @return [Array<Hash>] Details of each failed event
    attr_reader :failed_events
    # @return [Integer] Number of events that published successfully
    attr_reader :successful_count

    # @param message [String, nil] Human-readable error message
    # @param failed_events [Array<Hash>] Failed event details
    # @param successful_count [Integer] Count of successful publishes
    # @param context [Hash] Additional diagnostic context
    def initialize(message = nil, failed_events: [], successful_count: 0, context: {})
      @failed_events = failed_events
      @successful_count = successful_count
      super(
        message,
        context: context.merge(
          failed_count: failed_events.size,
          successful_count: successful_count
        )
      )
    end
  end

  # Raised when message consumption encounters an error.
  class ConsumerError < Error
    # @return [String, nil] Event ID being processed
    attr_reader :event_id
    # @return [Integer, nil] Number of delivery attempts so far
    attr_reader :deliveries

    # @param message [String, nil] Human-readable error message
    # @param event_id [String, nil] The event ID being consumed
    # @param deliveries [Integer, nil] Delivery attempt count
    # @param context [Hash] Additional diagnostic context
    def initialize(message = nil, event_id: nil, deliveries: nil, context: {})
      @event_id = event_id
      @deliveries = deliveries
      super(message, context: context.merge(event_id: event_id, deliveries: deliveries).compact)
    end
  end

  # Raised when a user-provided handler raises during event processing.
  class HandlerError < ConsumerError; end

  # Raised when the inbox deduplication layer encounters an error.
  class InboxError < ConsumerError; end

  # Raised when stream or consumer topology operations fail.
  class TopologyError < Error; end

  # Raised when a JetStream consumer cannot be provisioned.
  class ConsumerProvisioningError < TopologyError; end

  # Raised when the configured stream does not exist.
  class StreamNotFoundError < TopologyError; end

  # Raised when subject filter patterns overlap between consumers.
  class SubjectOverlapError < TopologyError; end

  # Raised when stream creation fails.
  class StreamCreationFailedError < TopologyError; end

  # Raised when a DLQ operation fails.
  class DlqError < Error; end

  # Raised when publishing a message to the dead letter queue fails.
  class DlqPublishFailedError < DlqError; end

  # Raised when all retry attempts have been exhausted.
  class RetryExhausted < Error
    # @return [Integer] Total number of attempts made
    attr_reader :attempts
    # @return [Exception, nil] The last error that triggered the retry
    attr_reader :original_error

    # @param message [String, nil] Human-readable error message (auto-generated if nil)
    # @param attempts [Integer] Number of attempts made
    # @param original_error [Exception, nil] The underlying error
    # @param context [Hash] Additional diagnostic context
    def initialize(message = nil, attempts: 0, original_error: nil, context: {})
      @attempts = attempts
      @original_error = original_error
      super(
        message || "Failed after #{attempts} attempts: #{original_error&.message}",
        context: context.merge(attempts: attempts).compact
      )
    end
  end
end
