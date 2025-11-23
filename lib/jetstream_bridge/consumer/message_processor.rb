# frozen_string_literal: true

require 'oj'
require 'securerandom'
require_relative '../core/logging'
require_relative '../models/event'
require_relative 'dlq_publisher'
require_relative 'middleware'

module JetstreamBridge
  # Immutable per-message metadata.
  MessageContext = Struct.new(
    :event_id, :deliveries, :subject, :seq, :consumer, :stream,
    keyword_init: true
  ) do
    def self.build(msg)
      new(
        event_id: msg.header&.[]('nats-msg-id') || SecureRandom.uuid,
        deliveries: msg.metadata&.num_delivered.to_i,
        subject: msg.subject,
        seq: msg.metadata&.sequence,
        consumer: msg.metadata&.consumer,
        stream: msg.metadata&.stream
      )
    end
  end

  # Simple exponential backoff strategy for transient failures.
  class BackoffStrategy
    TRANSIENT_ERRORS = [Timeout::Error, IOError].freeze
    MAX_EXPONENT     = 6
    MAX_DELAY        = 60
    MIN_DELAY        = 1

    # Returns a bounded delay in seconds
    def delay(deliveries, error)
      base = transient?(error) ? 0.5 : 2.0
      power = [deliveries - 1, MAX_EXPONENT].min
      raw = (base * (2**power)).to_i
      raw.clamp(MIN_DELAY, MAX_DELAY)
    end

    private

    def transient?(error)
      TRANSIENT_ERRORS.any? { |k| error.is_a?(k) }
    end
  end

  # Orchestrates parse → handler → ack/nak → DLQ
  class MessageProcessor
    UNRECOVERABLE_ERRORS = [ArgumentError, TypeError].freeze

    attr_reader :middleware_chain

    def initialize(jts, handler, dlq: nil, backoff: nil, middleware_chain: nil)
      @jts              = jts
      @handler          = handler
      @dlq              = dlq || DlqPublisher.new(jts)
      @backoff          = backoff || BackoffStrategy.new
      @middleware_chain = middleware_chain || ConsumerMiddleware::MiddlewareChain.new
    end

    def handle_message(msg)
      ctx   = MessageContext.build(msg)
      event = parse_message(msg, ctx)
      return unless event

      process_event(msg, event, ctx)
    rescue StandardError => e
      backtrace = e.backtrace&.first(5)&.join("\n  ")
      Logging.error(
        "Processor crashed event_id=#{ctx&.event_id} subject=#{ctx&.subject} seq=#{ctx&.seq} " \
        "deliveries=#{ctx&.deliveries} err=#{e.class}: #{e.message}\n  #{backtrace}",
        tag: 'JetstreamBridge::Consumer'
      )
      safe_nak(msg, ctx, e)
    end

    private

    def parse_message(msg, ctx)
      data = msg.data
      Oj.load(data, mode: :strict)
    rescue Oj::ParseError => e
      dlq_success = @dlq.publish(msg, ctx,
                                 reason: 'malformed_json', error_class: e.class.name, error_message: e.message)
      if dlq_success
        msg.ack
        Logging.warn(
          "Malformed JSON → DLQ event_id=#{ctx.event_id} subject=#{ctx.subject} " \
          "seq=#{ctx.seq} deliveries=#{ctx.deliveries}: #{e.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      else
        safe_nak(msg, ctx, e)
        Logging.error(
          "Malformed JSON, DLQ publish failed, NAKing event_id=#{ctx.event_id}",
          tag: 'JetstreamBridge::Consumer'
        )
      end
      nil
    end

    def process_event(msg, event_hash, ctx)
      # Convert hash to Event object
      event = build_event_object(event_hash, ctx)

      # Call handler through middleware chain
      if @middleware_chain
        @middleware_chain.call(event) { call_handler(event, event_hash, ctx) }
      else
        call_handler(event, event_hash, ctx)
      end

      msg.ack
      Logging.info(
        "ACK event_id=#{ctx.event_id} subject=#{ctx.subject} seq=#{ctx.seq} deliveries=#{ctx.deliveries}",
        tag: 'JetstreamBridge::Consumer'
      )
    rescue *UNRECOVERABLE_ERRORS => e
      dlq_success = @dlq.publish(msg, ctx,
                                 reason: 'unrecoverable', error_class: e.class.name, error_message: e.message)
      if dlq_success
        msg.ack
        Logging.warn(
          "DLQ (unrecoverable) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
          "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{e.class}: #{e.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      else
        safe_nak(msg, ctx, e)
        Logging.error(
          "Unrecoverable error, DLQ publish failed, NAKing event_id=#{ctx.event_id}",
          tag: 'JetstreamBridge::Consumer'
        )
      end
    rescue StandardError => e
      ack_or_nak(msg, ctx, e)
    end

    def ack_or_nak(msg, ctx, error)
      max_deliver = JetstreamBridge.config.max_deliver.to_i
      if ctx.deliveries >= max_deliver
        # Only ACK if DLQ publish succeeds
        dlq_success = @dlq.publish(msg, ctx,
                                   reason: 'max_deliver_exceeded',
                                   error_class: error.class.name,
                                   error_message: error.message)

        if dlq_success
          msg.ack
          Logging.warn(
            "DLQ (max_deliver) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
            "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
            tag: 'JetstreamBridge::Consumer'
          )
        else
          # NAK to retry DLQ publish
          safe_nak(msg, ctx, error)
          Logging.error(
            "DLQ publish failed at max_deliver, NAKing event_id=#{ctx.event_id} " \
            "seq=#{ctx.seq} deliveries=#{ctx.deliveries}",
            tag: 'JetstreamBridge::Consumer'
          )
        end
      else
        safe_nak(msg, ctx, error)
        Logging.warn(
          "NAK event_id=#{ctx.event_id} subject=#{ctx.subject} seq=#{ctx.seq} " \
          "deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      end
    end

    def safe_nak(msg, ctx = nil, error = nil)
      # Use backoff strategy with error context if available
      if ctx && error && msg.respond_to?(:nak_with_delay)
        delay = @backoff.delay(ctx.deliveries.to_i, error)
        msg.nak_with_delay(delay)
      else
        msg.nak
      end
    rescue StandardError => e
      Logging.error(
        "Failed to NAK event_id=#{ctx&.event_id} deliveries=#{ctx&.deliveries}: " \
        "#{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    # Build Event object from hash and context
    def build_event_object(event_hash, ctx)
      Models::Event.new(
        event_hash,
        metadata: {
          subject: ctx.subject,
          deliveries: ctx.deliveries,
          stream: ctx.stream,
          sequence: ctx.seq,
          consumer: ctx.consumer,
          timestamp: Time.now
        }
      )
    end

    # Call handler with Event object
    def call_handler(event, _event_hash, _ctx)
      @handler.call(event)
    end
  end
end
