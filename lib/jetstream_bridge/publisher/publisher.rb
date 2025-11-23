# frozen_string_literal: true

require 'oj'
require 'securerandom'
require_relative '../core/connection'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative '../core/retry_strategy'
require_relative '../models/publish_result'
require_relative 'outbox_repository'

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
    # Initialize a new Publisher instance.
    #
    # @param retry_strategy [RetryStrategy, nil] Optional custom retry strategy for handling transient failures.
    #   Defaults to PublisherRetryStrategy with exponential backoff.
    # @raise [ConnectionError] If unable to connect to NATS server
    def initialize(retry_strategy: nil)
      @jts = Connection.connect!
      @retry_strategy = retry_strategy || PublisherRetryStrategy.new
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
    def publish(event_or_hash = nil, resource_type: nil, event_type: nil, payload: nil, subject: nil, **options)
      ensure_destination!

      params = { event_or_hash: event_or_hash, resource_type: resource_type, event_type: event_type,
                 payload: payload, subject: subject, options: options }
      envelope, resolved_subject = route_publish_params(params)

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
      if JetstreamBridge.config.use_outbox
        publish_via_outbox(subject, envelope)
      else
        with_retries { publish_to_nats(subject, envelope) }
      end
    end

    private

    # Routes publish parameters to appropriate envelope builder
    # @return [Array<Hash, String>] tuple of [envelope, subject]
    def route_publish_params(params)
      if structured_params?(params)
        build_from_structured_params(params)
      elsif keyword_or_hash_params?(params)
        build_from_keyword_or_hash(params)
      else
        raise ArgumentError, 'Either provide (resource_type:, event_type:, payload:) or an event hash'
      end
    end

    def structured_params?(params)
      params[:resource_type] && params[:event_type] && params[:payload]
    end

    def keyword_or_hash_params?(params)
      params[:event_type] || params[:payload] || params[:event_or_hash].is_a?(Hash)
    end

    def build_from_structured_params(params)
      envelope = build_envelope(params[:resource_type], params[:event_type], params[:payload], params[:options])
      resolved_subject = params[:subject] || JetstreamBridge.config.source_subject
      [envelope, resolved_subject]
    end

    def build_from_keyword_or_hash(params)
      envelope = if params[:event_or_hash].is_a?(Hash)
                   normalize_envelope(params[:event_or_hash], params[:options])
                 else
                   build_from_keywords(params[:event_type], params[:payload], params[:options])
                 end

      resolved_subject = params[:subject] || params[:options][:subject] || JetstreamBridge.config.source_subject
      [envelope, resolved_subject]
    end

    def build_from_keywords(event_type, payload, options)
      raise ArgumentError, 'event_type is required' unless event_type
      raise ArgumentError, 'payload is required' unless payload

      normalize_envelope({ 'event_type' => event_type, 'payload' => payload }, options)
    end

    def ensure_destination!
      return unless JetstreamBridge.config.destination_app.to_s.empty?

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
      klass = ModelUtils.constantize(JetstreamBridge.config.outbox_model)

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

    def build_envelope(resource_type, event_type, payload, options = {})
      {
        'event_id' => options[:event_id] || SecureRandom.uuid,
        'schema_version' => 1,
        'event_type' => event_type,
        'producer' => JetstreamBridge.config.app_name,
        'resource_id' => (payload['id'] || payload[:id]).to_s,
        'occurred_at' => (options[:occurred_at] || Time.now.utc).iso8601,
        'trace_id' => options[:trace_id] || SecureRandom.hex(8),
        'resource_type' => resource_type,
        'payload' => payload
      }
    end

    # Normalize a hash to match envelope structure, allowing partial envelopes
    def normalize_envelope(hash, options = {})
      hash = hash.transform_keys(&:to_s)
      infer_resource_type_if_needed!(hash)

      {
        'event_id' => envelope_event_id(hash, options),
        'schema_version' => hash['schema_version'] || 1,
        'event_type' => hash['event_type'] || raise(ArgumentError, 'event_type is required'),
        'producer' => hash['producer'] || JetstreamBridge.config.app_name,
        'resource_id' => hash['resource_id'] || extract_resource_id(hash['payload']),
        'occurred_at' => envelope_occurred_at(hash, options),
        'trace_id' => envelope_trace_id(hash, options),
        'resource_type' => hash['resource_type'] || 'event',
        'payload' => hash['payload'] || raise(ArgumentError, 'payload is required')
      }
    end

    def infer_resource_type_if_needed!(hash)
      return unless hash['event_type'] && hash['payload'] && !hash['resource_type']

      # Try to infer from dot notation (e.g., 'user.created' -> 'user')
      parts = hash['event_type'].split('.')
      hash['resource_type'] = parts[0] if parts.size > 1
    end

    def envelope_event_id(hash, options)
      hash['event_id'] || options[:event_id] || SecureRandom.uuid
    end

    def envelope_occurred_at(hash, options)
      hash['occurred_at'] || (options[:occurred_at] || Time.now.utc).iso8601
    end

    def envelope_trace_id(hash, options)
      hash['trace_id'] || options[:trace_id] || SecureRandom.hex(8)
    end

    def extract_resource_id(payload)
      return '' unless payload

      payload = payload.transform_keys(&:to_s) if payload.respond_to?(:transform_keys)
      (payload['id'] || payload[:id] || payload['resource_id'] || payload[:resource_id]).to_s
    end
  end
end
