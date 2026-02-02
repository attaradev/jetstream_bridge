# frozen_string_literal: true

module JetstreamBridge
  # Base error for all JetStream Bridge errors with context support
  class Error < StandardError
    attr_reader :context

    def initialize(message = nil, context: {})
      super(message)
      @context = context.freeze
    end
  end

  # Configuration errors
  class ConfigurationError < Error; end
  class InvalidSubjectError < ConfigurationError; end
  class MissingConfigurationError < ConfigurationError; end

  # Connection errors
  class ConnectionError < Error; end
  class ConnectionNotEstablishedError < ConnectionError; end
  class HealthCheckFailedError < ConnectionError; end

  # Publisher errors with enriched context
  class PublishError < Error
    attr_reader :event_id, :subject

    def initialize(message = nil, event_id: nil, subject: nil, context: {})
      @event_id = event_id
      @subject = subject
      super(message, context: context.merge(event_id: event_id, subject: subject).compact)
    end
  end

  class PublishFailedError < PublishError; end
  class OutboxError < PublishError; end

  class BatchPublishError < PublishError
    attr_reader :failed_events, :successful_count

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

  # Consumer errors with delivery context
  class ConsumerError < Error
    attr_reader :event_id, :deliveries

    def initialize(message = nil, event_id: nil, deliveries: nil, context: {})
      @event_id = event_id
      @deliveries = deliveries
      super(message, context: context.merge(event_id: event_id, deliveries: deliveries).compact)
    end
  end

  class HandlerError < ConsumerError; end
  class InboxError < ConsumerError; end

  # Topology errors
  class TopologyError < Error; end
  class ConsumerProvisioningError < TopologyError; end
  class StreamNotFoundError < TopologyError; end
  class SubjectOverlapError < TopologyError; end
  class StreamCreationFailedError < TopologyError; end

  # DLQ errors
  class DlqError < Error; end
  class DlqPublishFailedError < DlqError; end

  # Retry errors
  class RetryExhausted < Error
    attr_reader :attempts, :original_error

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
