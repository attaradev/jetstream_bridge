# frozen_string_literal: true

module JetstreamBridge
  # Base error for all JetStream Bridge errors
  class Error < StandardError; end

  # Configuration errors
  class ConfigurationError < Error; end
  class InvalidSubjectError < ConfigurationError; end
  class MissingConfigurationError < ConfigurationError; end

  # Connection errors
  class ConnectionError < Error; end
  class ConnectionNotEstablishedError < ConnectionError; end
  class HealthCheckFailedError < ConnectionError; end

  # Publisher errors
  class PublishError < Error; end
  class PublishFailedError < PublishError; end
  class OutboxError < PublishError; end

  # Consumer errors
  class ConsumerError < Error; end
  class HandlerError < ConsumerError; end
  class InboxError < ConsumerError; end

  # Topology errors
  class TopologyError < Error; end
  class StreamNotFoundError < TopologyError; end
  class SubjectOverlapError < TopologyError; end
  class StreamCreationFailedError < TopologyError; end

  # DLQ errors
  class DlqError < Error; end
  class DlqPublishFailedError < DlqError; end

  # Retry errors (already defined in retry_strategy.rb)
  # class RetryExhausted < Error; end
end
