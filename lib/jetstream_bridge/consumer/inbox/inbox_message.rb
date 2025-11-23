# frozen_string_literal: true

require 'oj'
require 'securerandom'

module JetstreamBridge
  # Immutable value object for a single NATS message.
  class InboxMessage
    attr_reader :msg, :seq, :deliveries, :stream, :subject, :headers, :body, :raw, :event_id, :now

    def self.from_nats(msg)
      meta       = (msg.respond_to?(:metadata) && msg.metadata) || nil
      seq        = meta.respond_to?(:stream_sequence) ? meta.stream_sequence : nil
      deliveries = meta.respond_to?(:num_delivered)   ? meta.num_delivered   : nil
      stream     = meta.respond_to?(:stream)          ? meta.stream          : nil
      consumer   = meta.respond_to?(:consumer)        ? meta.consumer        : nil
      subject    = msg.subject.to_s

      headers = {}
      (msg.header || {}).each { |k, v| headers[k.to_s.downcase] = v }

      raw  = msg.data
      body = begin
        Oj.load(raw, mode: :strict)
      rescue Oj::Error
        {}
      end

      id = (headers['nats-msg-id'] || body['event_id']).to_s.strip
      id = "seq:#{seq}" if id.empty? && seq
      id = SecureRandom.uuid if id.to_s.empty?

      new(msg, seq, deliveries, stream, subject, headers, body, raw, id, Time.now.utc, consumer)
    end

    def initialize(msg, seq, deliveries, stream, subject, headers, body, raw, event_id, now, consumer = nil)
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
      @consumer   = consumer
    end

    def body_for_store
      body.empty? ? raw : body
    end

    def data
      raw
    end

    def header
      headers
    end

    def metadata
      @metadata ||= Struct.new(:num_delivered, :sequence, :consumer, :stream)
                          .new(deliveries, seq, @consumer, stream)
    end

    def ack(*, **)
      msg.ack(*, **) if msg.respond_to?(:ack)
    end

    def nak(*, **)
      msg.nak(*, **) if msg.respond_to?(:nak)
    end
  end
end
