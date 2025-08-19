# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'logging'
require_relative 'config'
require_relative 'model_utils'

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

      now = Time.now.utc
      event_id = envelope['event_id'].to_s

      record = ModelUtils.find_or_init_by_best(
        klass,
        { event_id: event_id },
        # Fallback key if app uses a different unique column:
        { dedup_key: event_id }
      )

      # If already sent, do nothing
      if record.respond_to?(:sent_at) && record.sent_at
        Logging.info("Outbox already sent event_id=#{event_id}; skipping publish.",
                     tag: 'JetstreamBridge::Publisher')
        return true
      end

      # populate / update
      ModelUtils.assign_known_attrs(record, {
        event_id:      event_id,
        subject:       subject,
        payload:       ModelUtils.json_dump(envelope),
        headers:       ModelUtils.json_dump({ 'Nats-Msg-Id' => event_id }),
        status:        'publishing',
        attempts:      (record.respond_to?(:attempts) ? (record.attempts || 0) + 1 : nil),
        last_error:    nil,
        enqueued_at:   (record.respond_to?(:enqueued_at) ? (record.enqueued_at || now) : nil),
        updated_at:    (record.respond_to?(:updated_at) ? now : nil)
      })
      record.save!

      ok = with_retries { do_publish(subject, envelope) }

      if ok
        ModelUtils.assign_known_attrs(record, {
          status:   'sent',
          sent_at:  (record.respond_to?(:sent_at) ? now : nil),
          updated_at: (record.respond_to?(:updated_at) ? now : nil)
        })
        record.save!
      else
        ModelUtils.assign_known_attrs(record, {
          status:     'failed',
          last_error: 'Publish returned false',
          updated_at: (record.respond_to?(:updated_at) ? now : nil)
        })
        record.save!
      end

      ok
    rescue => e
      # Persist the failure on the outbox row as best as we can
      begin
        if record
          ModelUtils.assign_known_attrs(record, {
            status:     'failed',
            last_error: "#{e.class}: #{e.message}",
            updated_at: (record.respond_to?(:updated_at) ? Time.now.utc : nil)
          })
          record.save!
        end
      rescue => e2
        Logging.warn("Failed to persist outbox failure: #{e2.class}: #{e2.message}",
                     tag: 'JetstreamBridge::Publisher')
      end
      log_error(false, e)
    end
    # ---- /Outbox path ----

    # Retry only on transient NATS IO errors
    def with_retries(retries = DEFAULT_RETRIES)
      attempts = 0
      begin
        return yield
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
        'event_id'       => options[:event_id] || SecureRandom.uuid,
        'schema_version' => 1,
        'event_type'     => event_type,
        'producer'       => JetstreamBridge.config.app_name,
        'resource_id'    => (payload['id'] || payload[:id]).to_s,
        'occurred_at'    => (options[:occurred_at] || Time.now.utc).iso8601,
        'trace_id'       => options[:trace_id] || SecureRandom.hex(8),
        'resource_type'  => resource_type,
        'payload'        => payload
      }
    end
  end
end
