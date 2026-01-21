# frozen_string_literal: true

require 'oj'
require 'securerandom'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative '../core/retry_strategy'
require_relative '../models/publish_result'
require_relative 'outbox_repository'
require_relative 'event_envelope_builder'

module JetstreamBridge
  # Publishes events to NATS JetStream with reliability features.
  #
  # Publishes events to "{env}.{app}.sync.{dest}" subject pattern.
  # Supports optional transactional outbox pattern for guaranteed delivery.
  #
  # @example Basic publishing
  #   publisher = JetstreamBridge::Publisher.new
  #   result = publisher.publish(
  #     resource_type: "user",
  #     event_type: "created",
  #     payload: { id: 1, email: "ada@example.com" }
  #   )
  #   puts "Published: #{result.event_id}" if result.success?
  #
  # @example Publishing with custom retry strategy
  #   custom_strategy = MyRetryStrategy.new(max_attempts: 5)
  #   publisher = JetstreamBridge::Publisher.new(retry_strategy: custom_strategy)
  #   result = publisher.publish(event_type: "user.created", payload: { id: 1 })
  #
  # @example Using convenience method
  #   JetstreamBridge.publish(event_type: "user.created", payload: { id: 1 })
  #
  class Publisher
    # Initialize a new Publisher instance with dependency injection.
    #
    # @param connection [NATS::JetStream::JS] JetStream connection
    # @param config [Config] Configuration instance
    # @param retry_strategy [RetryStrategy, nil] Optional custom retry strategy
    # @raise [ArgumentError] If required dependencies are missing
    def initialize(connection:, config:, retry_strategy: nil)
      raise ArgumentError, 'connection is required' unless connection
      raise ArgumentError, 'config is required' unless config

      @jts = connection
      @config = config
      @retry_strategy = retry_strategy || PublisherRetryStrategy.new
      @envelope_builder = EventEnvelopeBuilder
    end

    # Publishes an event to NATS JetStream.
    #
    # Supports multiple usage patterns for flexibility:
    #
    # 1. Structured parameters (recommended):
    #    publish(resource_type: 'user', event_type: 'created', payload: { id: 1, name: 'Ada' })
    #
    # 2. Hash/envelope with dot notation (auto-infers resource_type):
    #    publish(event_type: 'user.created', payload: {...})
    #
    # 3. Complete envelope (advanced):
    #    publish({ event_type: 'created', resource_type: 'user', payload: {...}, event_id: '...' })
    #
    # When use_outbox is enabled, events are persisted to database first for reliability.
    # The event_id is used for deduplication via NATS message ID header.
    #
    # @param event_or_hash [Hash, nil] Complete event envelope (if using pattern 3)
    # @param resource_type [String, nil] Resource type (e.g., 'user', 'order'). Required for pattern 1.
    # @param event_type [String, nil] Event type (e.g., 'created', 'user.created'). Required for all patterns.
    # @param payload [Hash, nil] Event payload data. Required for all patterns.
    # @param subject [String, nil] Optional NATS subject override. Defaults to config.source_subject.
    # @param options [Hash] Additional options:
    #   - event_id [String] Custom event ID (auto-generated if not provided)
    #   - trace_id [String] Distributed trace ID
    #   - occurred_at [Time, String] Event timestamp (defaults to current time)
    #
    # @return [Models::PublishResult] Result object containing:
    #   - success [Boolean] Whether publish succeeded
    #   - event_id [String] The published event ID
    #   - subject [String] NATS subject used
    #   - error [Exception, nil] Error if publish failed
    #   - duplicate [Boolean] Whether NATS detected as duplicate
    #
    # @raise [ArgumentError] If required parameters are missing or invalid
    #
    # @example Structured parameters
    #   result = publisher.publish(
    #     resource_type: "user",
    #     event_type: "created",
    #     payload: { id: 1, email: "ada@example.com" }
    #   )
    #   puts "Published: #{result.event_id}" if result.success?
    #
    # @example With options
    #   result = publisher.publish(
    #     event_type: "user.created",
    #     payload: { id: 1 },
    #     event_id: "custom-id-123",
    #     trace_id: request_id,
    #     occurred_at: Time.now.utc
    #   )
    #
    # @example Error handling
    #   result = publisher.publish(event_type: "order.created", payload: { id: 1 })
    #   if result.failure?
    #     logger.error "Failed to publish: #{result.error.message}"
    #   end
    #
    def publish(event_type:, payload:, resource_type: nil, subject: nil, **options)
      ensure_destination_app_configured!

      envelope = @envelope_builder.build(
        event_type: event_type,
        payload: payload,
        resource_type: resource_type,
        **options
      )

      resolved_subject = subject || @config.source_subject

      do_publish(resolved_subject, envelope)
    rescue ArgumentError
      # Re-raise validation errors for invalid parameters
      raise
    rescue StandardError => e
      # Return failure result for publishing errors
      Models::PublishResult.new(
        success: false,
        event_id: envelope&.[]('event_id') || 'unknown',
        subject: resolved_subject || 'unknown',
        error: e
      )
    end

    # Publish a complete event envelope (advanced usage)
    #
    # Provides full control over the envelope structure. Use this when you need
    # to manually construct the envelope or preserve all fields from an external source.
    #
    # @param envelope [Hash] Complete event envelope with all required fields
    # @option envelope [String] 'event_id' Unique event identifier (required)
    # @option envelope [Integer] 'schema_version' Schema version (required, typically 1)
    # @option envelope [String] 'event_type' Event type (required)
    # @option envelope [String] 'producer' Producer name (required)
    # @option envelope [String] 'resource_type' Resource type (required)
    # @option envelope [String] 'resource_id' Resource identifier (required)
    # @option envelope [String] 'occurred_at' ISO8601 timestamp (required)
    # @option envelope [String] 'trace_id' Trace identifier (required)
    # @option envelope [Hash] 'payload' Event payload data (required)
    # @param subject [String, nil] Optional NATS subject override
    # @return [Models::PublishResult] Result object
    #
    # @raise [ArgumentError] If required envelope fields are missing
    #
    # @example Publishing a complete envelope
    #   envelope = {
    #     'event_id' => SecureRandom.uuid,
    #     'schema_version' => 1,
    #     'event_type' => 'user.created',
    #     'producer' => 'custom-producer',
    #     'resource_type' => 'user',
    #     'resource_id' => '123',
    #     'occurred_at' => Time.now.utc.iso8601,
    #     'trace_id' => 'trace-123',
    #     'payload' => { id: 123, name: 'Alice' }
    #   }
    #
    #   result = publisher.publish_envelope(envelope)
    #   puts "Published: #{result.event_id}"
    def publish_envelope(envelope, subject: nil)
      ensure_destination_app_configured!
      validate_envelope!(envelope)

      resolved_subject = subject || @config.source_subject

      do_publish(resolved_subject, envelope)
    rescue ArgumentError
      # Re-raise validation errors for invalid envelope
      raise
    rescue StandardError => e
      # Return failure result for publishing errors
      Models::PublishResult.new(
        success: false,
        event_id: envelope&.[]('event_id') || 'unknown',
        subject: resolved_subject || 'unknown',
        error: e
      )
    end

    # Internal publish method that routes to appropriate publish strategy.
    #
    # Routes to outbox-based publishing if use_outbox is enabled, otherwise
    # publishes directly to NATS with retry logic.
    #
    # @param subject [String] NATS subject to publish to
    # @param envelope [Hash] Complete event envelope
    # @return [Models::PublishResult] Result object
    # @api private
    def do_publish(subject, envelope)
      if @config.use_outbox
        publish_via_outbox(subject, envelope)
      else
        with_retries { publish_to_nats(subject, envelope) }
      end
    end

    private

    # Validate envelope has all required fields
    def validate_envelope!(envelope)
      required_fields = %w[event_id schema_version event_type producer resource_type
                           resource_id occurred_at trace_id payload]

      missing = required_fields.select { |field| envelope[field].nil? || envelope[field].to_s.strip.empty? }

      return if missing.empty?

      raise ArgumentError, "Envelope missing required fields: #{missing.join(', ')}"
    end

    def ensure_destination_app_configured!
      return unless @config.destination_app.to_s.empty?

      raise ArgumentError, 'destination_app must be configured'
    end

    def publish_to_nats(subject, envelope)
      headers = { 'nats-msg-id' => envelope['event_id'] }

      ack = @jts.publish(subject, Oj.dump(envelope, mode: :compat), header: headers)
      duplicate = ack.respond_to?(:duplicate?) && ack.duplicate?
      msg = "Published #{subject} event_id=#{envelope['event_id']}"
      msg += ' (duplicate)' if duplicate

      Logging.info(msg, tag: 'JetstreamBridge::Publisher')

      if ack.respond_to?(:error) && ack.error
        Logging.error(
          "Publish ack error: #{ack.error}",
          tag: 'JetstreamBridge::Publisher'
        )
        return Models::PublishResult.new(
          success: false,
          event_id: envelope['event_id'],
          subject: subject,
          error: StandardError.new(ack.error.to_s),
          duplicate: duplicate
        )
      end

      Models::PublishResult.new(
        success: true,
        event_id: envelope['event_id'],
        subject: subject,
        duplicate: duplicate
      )
    end

    # ---- Outbox path ----
    def publish_via_outbox(subject, envelope)
      klass = ModelUtils.constantize(@config.outbox_model)

      unless ModelUtils.ar_class?(klass)
        Logging.warn(
          "Outbox model #{klass} is not an ActiveRecord model; publishing directly.",
          tag: 'JetstreamBridge::Publisher'
        )
        return with_retries { publish_to_nats(subject, envelope) }
      end

      repo     = OutboxRepository.new(klass)
      event_id = envelope['event_id'].to_s
      record   = repo.find_or_build(event_id)

      if repo.already_sent?(record)
        Logging.info(
          "Outbox already sent event_id=#{event_id}; skipping publish.",
          tag: 'JetstreamBridge::Publisher'
        )
        return Models::PublishResult.new(
          success: true,
          event_id: event_id,
          subject: subject,
          duplicate: true
        )
      end

      repo.persist_pre(record, subject, envelope)

      result = with_retries { publish_to_nats(subject, envelope) }
      if result.success?
        repo.persist_success(record)
      else
        repo.persist_failure(record, result.error&.message || 'Publish failed')
      end
      result
    rescue StandardError => e
      repo.persist_exception(record, e) if defined?(repo) && defined?(record)
      Models::PublishResult.new(
        success: false,
        event_id: envelope['event_id'],
        subject: subject,
        error: e
      )
    end
    # ---- /Outbox path ----

    # Retry using strategy pattern
    def with_retries(&)
      @retry_strategy.execute(context: 'Publisher', &)
    rescue RetryStrategy::RetryExhausted => e
      Logging.error(
        "Publish failed after retries: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Publisher'
      )
      raise
    end
  end
end
