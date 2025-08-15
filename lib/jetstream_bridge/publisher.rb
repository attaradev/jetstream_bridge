# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'logging'

module JetstreamBridge
  # Publishes to: data.sync.{app}.{dest}.{resource}.{event}
  class Publisher
    DEFAULT_RETRIES  = 2
    RETRY_BACKOFFS   = [0.25, 1.0].freeze

    def initialize
      @js = Connection.connect!
    end

    def publish(resource_type:, event_type:, payload:, **options)
      ensure_destination!
      subject  = "#{JetstreamBridge.config.source_subject}.#{resource_type}.#{event_type}"
      envelope = build_envelope(resource_type, event_type, payload, **options)
      headers  = { 'Nats-Msg-Id' => envelope['event_id'] }

      publish_with_retries(subject, JSON.generate(envelope), headers)
      Logging.info("Published #{subject} event_id=#{envelope['event_id']}", tag: 'JetstreamBridge::Publisher')
      true
    rescue StandardError => e
      Logging.error("Publish failed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Publisher')
      false
    end

    private

    def ensure_destination!
      raise ArgumentError, 'destination_app must be configured' if JetstreamBridge.config.destination_app.to_s.empty?
    end

    def publish_with_retries(subject, data, header, retries = DEFAULT_RETRIES)
      attempts = 0
      begin
        @js.publish(subject, data, header: header)
      rescue NATS::IO::Timeout, NATS::IO::SocketError, NATS::IO::Error => e
        attempts += 1
        raise if attempts > retries

        delay = RETRY_BACKOFFS[attempts - 1] || RETRY_BACKOFFS.last
        Logging.warn("Publish retry #{attempts} after #{e.class}: #{e.message}",
                     tag: 'JetstreamBridge::Publisher')
        sleep delay
        retry
      end
    end

    def build_envelope(resource_type, event_type, payload, options = {})
      {
        'event_id' => options[:event_id] || SecureRandom.uuid,
        'schema_version' => 1,
        'producer' => JetstreamBridge.config.source_app,
        'resource_type' => resource_type,
        'resource_id' => (payload['id'] || payload[:id]).to_s,
        'event_type' => event_type,
        'occurred_at' => (options[:occurred_at] || Time.now.utc).iso8601,
        'trace_id' => options[:trace_id] || SecureRandom.hex(8),
        'payload' => payload
      }
    end
  end
end
