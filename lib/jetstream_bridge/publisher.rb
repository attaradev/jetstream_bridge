# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'logging'
require_relative 'config'

module JetstreamBridge
  # Publishes to "{env}.data.sync.{app}.{dest}".
  class Publisher
    DEFAULT_RETRIES = 2
    RETRY_BACKOFFS  = [0.25, 1.0].freeze
    TRANSIENT_ERRORS = [NATS::IO::Timeout,NATS::IO::SocketTimeoutError, NATS::IO::Error].freeze

    def initialize
      @jts = Connection.connect!
    end

    # @param resource_type [String] e.g., "user"
    # @param event_type [String] e.g., "created"
    # @param payload [Hash]
    # @return [Boolean]
    def publish(resource_type:, event_type:, payload:, **options)
      ensure_destination!
      envelope = build_envelope(resource_type, event_type, payload, options)
      subject  = JetstreamBridge.config.source_subject
      with_retries { do_publish(subject, envelope) }
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

    # Retry only on transient NATS errors (≤10 lines)
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
