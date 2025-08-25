# frozen_string_literal: true

require 'json'

module JetstreamBridge
  # Immutable value object for a single NATS message.
  class InboxMessage
    attr_reader :msg, :seq, :deliveries, :stream, :subject, :headers, :body, :raw, :event_id, :now

    def self.from_nats(msg)
      meta       = (msg.respond_to?(:metadata) && msg.metadata) || nil
      seq        = meta.respond_to?(:stream_sequence) ? meta.stream_sequence : nil
      deliveries = meta.respond_to?(:num_delivered)   ? meta.num_delivered   : nil
      stream     = meta.respond_to?(:stream)          ? meta.stream          : nil
      subject    = msg.subject.to_s

      headers = {}
      (msg.header || {}).each { |k, v| headers[k.to_s.downcase] = v }

      raw  = msg.data
      body = begin
        JSON.parse(raw)
      rescue StandardError
        {}
      end

      id = (headers['nats-msg-id'] || body['event_id']).to_s.strip
      id = "seq:#{seq}" if id.empty?

      new(msg, seq, deliveries, stream, subject, headers, body, raw, id, Time.now.utc)
    end

    def initialize(msg, seq, deliveries, stream, subject, headers, body, raw, event_id, now)
      @msg        = msg
      @seq        = seq
      @deliveries = deliveries
      @stream     = stream
      @subject    = subject
      @headers    = headers
      @body       = body
      @raw        = raw
      @event_id   = event_id
      @now        = now
    end

    def body_for_store
      body.empty? ? raw : body
    end
  end
end
