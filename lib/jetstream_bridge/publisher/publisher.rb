# frozen_string_literal: true

require 'oj'
require 'securerandom'
require_relative '../core/connection'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative '../core/retry_strategy'
require_relative 'outbox_repository'

module JetstreamBridge
  # Publishes to "{env}.{app}.sync.{dest}".
  class Publisher
    def initialize(retry_strategy: nil)
      @jts = Connection.connect!
      @retry_strategy = retry_strategy || PublisherRetryStrategy.new
    end

    # @return [Boolean]
    def publish(resource_type:, event_type:, payload:, **options)
      ensure_destination!
      envelope = build_envelope(resource_type, event_type, payload, options)
      subject  = JetstreamBridge.config.source_subject

      if JetstreamBridge.config.use_outbox
        publish_via_outbox(subject, envelope)
      else
        with_retries { publish_to_nats(subject, envelope) }
      end
    rescue StandardError => e
      log_error(false, e)
    end

    private

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
      end

      !ack.respond_to?(:error) || ack.error.nil?
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
        return true
      end

      repo.persist_pre(record, subject, envelope)

      ok = with_retries { publish_to_nats(subject, envelope) }
      ok ? repo.persist_success(record) : repo.persist_failure(record, 'Publish returned false')
      ok
    rescue StandardError => e
      repo.persist_exception(record, e) if defined?(repo) && defined?(record)
      log_error(false, e)
    end
    # ---- /Outbox path ----

    # Retry using strategy pattern
    def with_retries
      @retry_strategy.execute(context: 'Publisher') { yield }
    rescue RetryStrategy::RetryExhausted => e
      log_error(false, e)
    end

    def log_error(val, exc)
      Logging.error(
        "Publish failed: #{exc.class} #{exc.message}",
        tag: 'JetstreamBridge::Publisher'
      )
      val
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
  end
end
