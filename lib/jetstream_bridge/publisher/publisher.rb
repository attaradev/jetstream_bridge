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
  # Publishes to "{env}.{app}.sync.{dest}".
  class Publisher
    def initialize(retry_strategy: nil)
      @jts = Connection.connect!
      @retry_strategy = retry_strategy || PublisherRetryStrategy.new
    end

    # Publishes an event to NATS JetStream.
    #
    # Supports two usage patterns:
    #
    # 1. Structured parameters (recommended):
    #    publish(resource_type: 'user', event_type: 'created', payload: { id: 1, name: 'Ada' })
    #
    # 2. Hash/envelope (advanced):
    #    publish({ event_type: 'user.created', payload: {...}, event_id: '...', ... }, subject: 'custom.subject')
    #
    # @example Check result status
    #   result = publisher.publish(event_type: "user.created", payload: { id: 1 })
    #   if result.success?
    #     puts "Published event #{result.event_id}"
    #   else
    #     puts "Failed: #{result.error.message}"
    #   end
    #
    # @param event_or_hash [Hash] Either structured params or a complete event envelope
    # @param resource_type [String, nil] Resource type (e.g., 'user', 'order')
    # @param event_type [String, nil] Event type (e.g., 'created', 'updated')
    # @param payload [Hash, nil] Event payload data
    # @param subject [String, nil] Optional subject override
    # @return [Models::PublishResult] Result object with success status and metadata
    def publish(event_or_hash = nil, resource_type: nil, event_type: nil, payload: nil, subject: nil, **options)
      ensure_destination!

      params = { event_or_hash: event_or_hash, resource_type: resource_type, event_type: event_type,
                 payload: payload, subject: subject, options: options }
      envelope, resolved_subject = route_publish_params(params)

      do_publish(resolved_subject, envelope)
    rescue ArgumentError => e
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
    def with_retries(&block)
      @retry_strategy.execute(context: 'Publisher', &block)
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
