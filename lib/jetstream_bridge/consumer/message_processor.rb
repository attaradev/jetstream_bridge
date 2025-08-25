# frozen_string_literal: true

require 'oj'
require_relative '../core/logging'
require_relative 'message_context'
require_relative 'dlq_publisher'
require_relative 'backoff_strategy'

module JetstreamBridge
  # Orchestrates parse → handler → ack/nak → DLQ
  class MessageProcessor
    UNRECOVERABLE_ERRORS = [ArgumentError, TypeError].freeze

    def initialize(jts, handler, dlq: nil, backoff: nil)
      @jts     = jts
      @handler = handler
      @dlq     = dlq || DlqPublisher.new(jts)
      @backoff = backoff || BackoffStrategy.new
    end

    def handle_message(msg)
      ctx   = MessageContext.build(msg)
      event = parse_message(msg, ctx)
      return unless event

      process_event(msg, event, ctx)
    rescue StandardError => e
      Logging.error(
        "Processor crashed event_id=#{ctx&.event_id} subject=#{ctx&.subject} seq=#{ctx&.seq} " \
        "deliveries=#{ctx&.deliveries} err=#{e.class}: #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
      safe_nak(msg)
    end

    private

    def parse_message(msg, ctx)
      data = msg.data
      Oj.load(data, mode: :strict)
    rescue Oj::ParseError => e
      @dlq.publish(msg, ctx,
                   reason: 'malformed_json', error_class: e.class.name, error_message: e.message)
      msg.ack
      Logging.warn(
        "Malformed JSON → DLQ event_id=#{ctx.event_id} subject=#{ctx.subject} " \
        "seq=#{ctx.seq} deliveries=#{ctx.deliveries}: #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
      nil
    end

    def process_event(msg, event, ctx)
      @handler.call(event, ctx.subject, ctx.deliveries)
      msg.ack
      Logging.info(
        "ACK event_id=#{ctx.event_id} subject=#{ctx.subject} seq=#{ctx.seq} deliveries=#{ctx.deliveries}",
        tag: 'JetstreamBridge::Consumer'
      )
    rescue *UNRECOVERABLE_ERRORS => e
      @dlq.publish(msg, ctx,
                   reason: 'unrecoverable', error_class: e.class.name, error_message: e.message)
      msg.ack
      Logging.warn(
        "DLQ (unrecoverable) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
        "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{e.class}: #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    rescue StandardError => e
      ack_or_nak(msg, ctx, e)
    end

    def ack_or_nak(msg, ctx, error)
      max_deliver = JetstreamBridge.config.max_deliver.to_i
      if ctx.deliveries >= max_deliver
        @dlq.publish(msg, ctx,
                     reason: 'max_deliver_exceeded', error_class: error.class.name, error_message: error.message)
        msg.ack
        Logging.warn(
          "DLQ (max_deliver) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
          "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      else
        safe_nak(msg, ctx, error)
        Logging.warn(
          "NAK event_id=#{ctx.event_id} subject=#{ctx.subject} seq=#{ctx.seq} " \
          "deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      end
    end

    def safe_nak(msg, ctx = nil, _error = nil)
      # If your NATS client supports delayed NAKs, uncomment:
      # delay = @backoff.delay(ctx&.deliveries.to_i, error) if ctx
      # msg.nak(next_delivery_delay: delay)
      msg.nak
    rescue StandardError => e
      Logging.error(
        "Failed to NAK event_id=#{ctx&.event_id} deliveries=#{ctx&.deliveries}: " \
        "#{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
    end
  end
end
