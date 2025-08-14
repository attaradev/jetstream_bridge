# frozen_string_literal: true

require 'json'
require 'nats/io/client'
require 'securerandom'
require 'active_support/core_ext/string/inflections'

module JetstreamBridge
  # Publishes envelopes to JetStream; optionally persists Outbox first.
  class Publisher
    DEFAULT_RETRIES = 2
    RETRY_BACKOFFS = [0.25, 1.0].freeze # seconds

    def initialize(persistent: JetstreamBridge.config.publisher_persistent)
      @persistent = persistent
      connect!
    end

    # resource_type: "user", "request", etc.
    # event_type:    "created", "updated", "deleted"
    # payload:       Hash of domain fields OR full envelope if raw: true
    # options:       { event_id: "...", occurred_at: Time, trace_id: "...", raw: false }
    def publish(resource_type:, event_type:, payload:, **options)
      return outbox_write(resource_type, event_type, payload) if JetstreamBridge.config.use_outbox

      envelope = options[:raw] ? payload : build_envelope(resource_type, event_type, payload, **options)
      subject  = subject_for(resource_type, event_type)
      headers  = { 'Nats-Msg-Id' => envelope['event_id'] }

      with_publish_retries do
        connect!
        @js&.publish(subject, JSON.generate(envelope), header: headers)
      end

      log(:info, "Published #{subject} event_id=#{envelope['event_id']}")
      true
    rescue StandardError => e
      log(:error, "Publish failed: #{e.class} #{e.message}")
      false
    ensure
      close unless @persistent
    end

    # Flushes any pending Outbox rows to NATS (if use_outbox=true)
    def flush_outbox(batch_size: 100)
      return unless JetstreamBridge.config.use_outbox

      model = JetstreamBridge.config.outbox_model.constantize
      model.where(published_at: nil).order(:created_at).limit(batch_size).find_each do |row|
        envelope = build_envelope(row.resource_type, row.event_type, row.payload)
        subject  = subject_for(row.resource_type, row.event_type)
        headers  = { 'Nats-Msg-Id' => envelope['event_id'] }

        with_publish_retries do
          connect!
          @js&.publish(subject, JSON.generate(envelope), header: headers)
        end

        row.update!(published_at: Time.current, attempts: row.attempts + 1)
        log(:info, "Outbox published #{subject} event_id=#{envelope['event_id']}")
      rescue StandardError => e
        row.update!(attempts: row.attempts + 1, last_error: e.message)
        log(:warn, "Outbox failed: #{e.class} #{e.message}")
      end
    ensure
      close unless @persistent
    end

    def close
      @nc&.close
      @nc = @js = nil
    end

    private

    def connect!
      return if @nc && @js

      urls = (JetstreamBridge.config.nats_urls || 'nats://localhost:4222')
             .to_s.split(',').map(&:strip).reject(&:empty?)

      @nc&.close
      @nc = NATS::IO::Client.new
      @nc&.connect(servers: urls)
      @js = @nc&.jetstream
    end

    def with_publish_retries(max_retries: DEFAULT_RETRIES)
      attempts = 0
      begin
        yield
      rescue NATS::IO::Timeout, NATS::IO::SocketError, NATS::IO::Error => e
        raise if attempts >= max_retries

        sleep RETRY_BACKOFFS.fetch(attempts, RETRY_BACKOFFS.last)
        attempts += 1
        log(:warn, "Publish retry #{attempts} after #{e.class}: #{e.message}")
        connect!
        retry
      end
    end

    def outbox_write(resource_type, event_type, payload)
      model = JetstreamBridge.config.outbox_model.constantize
      model.create!(
        resource_type: resource_type,
        resource_id: (payload['id'] || payload[:id]).to_s,
        event_type: event_type,
        payload: payload
      )
      log(:info, "Queued to Outbox resource=#{resource_type} event=#{event_type}")
      true
    end

    def build_envelope(resource_type, event_type, payload,
                       event_id: SecureRandom.uuid,
                       occurred_at: Time.now.utc,
                       trace_id: SecureRandom.hex(8))
      producer = JetstreamBridge.config.source_app.presence || JetstreamBridge.config.app_name
      {
        'event_id' => event_id,
        'schema_version' => 1,
        'producer' => producer,
        'resource_type' => resource_type,
        'resource_id' => (payload['id'] || payload[:id]).to_s,
        'event_type' => event_type,
        'occurred_at' => occurred_at.iso8601,
        'trace_id' => trace_id,
        'payload' => payload
      }
    end

    def subject_for(resource_type, event_type)
      source = JetstreamBridge.config.source_app.presence || JetstreamBridge.config.app_name
      "#{JetstreamBridge.config.env}.data.sync.#{source}.#{resource_type}.#{event_type}"
    end

    def log(level, msg)
      if defined?(Rails)
        Rails.logger.public_send(level, "[JetstreamBridge::Publisher] #{msg}")
      else
        puts(msg)
      end
    end
  end
end
