# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative '../core/connection'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative 'outbox_repository'

module JetstreamBridge
  # Publishes to "{env}.data.sync.{app}.{dest}".
  class Publisher
    DEFAULT_RETRIES = 2
    RETRY_BACKOFFS  = [0.25, 1.0].freeze

    TRANSIENT_ERRORS = begin
      errs = [NATS::IO::Timeout, NATS::IO::Error]
      errs << NATS::IO::SocketTimeoutError if defined?(NATS::IO::SocketTimeoutError)
      errs.freeze
    end

    def initialize
      @jts = Connection.connect!
    end

    # @return [Boolean]
    def publish(resource_type:, event_type:, payload:, **options)
      ensure_destination!
      envelope = build_envelope(resource_type, event_type, payload, options)
      subject  = JetstreamBridge.config.source_subject

      if JetstreamBridge.config.use_outbox
        publish_via_outbox(subject, envelope)
      else
        with_retries { do_publish(subject, envelope) }
      end
    rescue StandardError => e
      log_error(false, e)
    end

    private

    def ensure_destination!
      return unless JetstreamBridge.config.destination_app.to_s.empty?

      raise ArgumentError, 'destination_app must be configured'
    end

    def do_publish(subject, envelope)
      headers = { 'Nats-Msg-Id' => envelope['event_id'] }
      @jts.publish(subject, JSON.generate(envelope), header: headers)
      Logging.info("Published #{subject} event_id=#{envelope['event_id']}",
                   tag: 'JetstreamBridge::Publisher')
      true
    end

    # ---- Outbox path ----
    def publish_via_outbox(subject, envelope)
      klass = ModelUtils.constantize(JetstreamBridge.config.outbox_model)

      unless ModelUtils.ar_class?(klass)
        Logging.warn("Outbox model #{klass} is not an ActiveRecord model; publishing directly.",
                     tag: 'JetstreamBridge::Publisher')
        return with_retries { do_publish(subject, envelope) }
      end

      repo     = OutboxRepository.new(klass)
      event_id = envelope['event_id'].to_s
      record   = repo.find_or_build(event_id)

      if repo.already_sent?(record)
        Logging.info("Outbox already sent event_id=#{event_id}; skipping publish.",
                     tag: 'JetstreamBridge::Publisher')
        return true
      end

      repo.persist_pre(record, subject, envelope)

      ok = with_retries { do_publish(subject, envelope) }
      ok ? repo.persist_success(record) : repo.persist_failure(record, 'Publish returned false')
      ok
    rescue StandardError => e
      repo.persist_exception(record, e) if defined?(repo) && defined?(record)
      log_error(false, e)
    end
    # ---- /Outbox path ----

    # Retry only on transient NATS IO errors
    def with_retries(retries = DEFAULT_RETRIES)
      attempts = 0
      begin
        yield
      rescue *TRANSIENT_ERRORS => e
        attempts += 1
        return log_error(false, e) if attempts > retries

        backoff(attempts, e)
        retry
      end
    end

    def backoff(attempts, error)
      delay = RETRY_BACKOFFS[attempts - 1] || RETRY_BACKOFFS.last
      Logging.warn("Publish retry #{attempts} after #{error.class}: #{error.message}",
                   tag: 'JetstreamBridge::Publisher')
      sleep delay
    end

    def log_error(val, exc)
      Logging.error("Publish failed: #{exc.class} #{exc.message}",
                    tag: 'JetstreamBridge::Publisher')
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
