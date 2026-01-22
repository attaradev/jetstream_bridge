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
    ActionResult = Struct.new(:action, :ctx, :error, :delay, keyword_init: true)

    attr_reader :middleware_chain

    def initialize(jts, handler, dlq: nil, backoff: nil, middleware_chain: nil)
      @jts              = jts
      @handler          = handler
      @dlq              = dlq || DlqPublisher.new(jts)
      @backoff          = backoff || BackoffStrategy.new
      @middleware_chain = middleware_chain || ConsumerMiddleware::MiddlewareChain.new
    end

    def handle_message(msg, auto_ack: true)
      ctx = MessageContext.build(msg)
      event, early_action = parse_message(msg, ctx)
      return apply_action(msg, early_action) if early_action && auto_ack
      return early_action if early_action

      result = process_event(msg, event, ctx)
      apply_action(msg, result) if auto_ack
      result
    rescue StandardError => e
      backtrace = e.backtrace&.first(5)&.join("\n  ")
      Logging.error(
        "Processor crashed event_id=#{ctx&.event_id} subject=#{ctx&.subject} seq=#{ctx&.seq} " \
        "deliveries=#{ctx&.deliveries} err=#{e.class}: #{e.message}\n  #{backtrace}",
        tag: 'JetstreamBridge::Consumer'
      )
      action = ActionResult.new(action: :nak, ctx: ctx, error: e)
      apply_action(msg, action) if auto_ack
      action
    end

    private

    def parse_message(msg, ctx)
      data = msg.data
      [Oj.load(data, mode: :strict), nil]
    rescue Oj::ParseError => e
      dlq_success = @dlq.publish(msg, ctx,
                                 reason: 'malformed_json', error_class: e.class.name, error_message: e.message)
      action = if dlq_success
                 Logging.warn(
                   "Malformed JSON → DLQ event_id=#{ctx.event_id} subject=#{ctx.subject} " \
                   "seq=#{ctx.seq} deliveries=#{ctx.deliveries}: #{e.message}",
                   tag: 'JetstreamBridge::Consumer'
                 )
                 ActionResult.new(action: :ack, ctx: ctx)
               else
                 Logging.error(
                   "Malformed JSON, DLQ publish failed, NAKing event_id=#{ctx.event_id}",
                   tag: 'JetstreamBridge::Consumer'
                 )
                 ActionResult.new(action: :nak, ctx: ctx, error: e,
                                  delay: backoff_delay(ctx, e))
               end
      [nil, action]
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

      ActionResult.new(action: :ack, ctx: ctx)
    rescue *UNRECOVERABLE_ERRORS => e
      dlq_action(msg, ctx, e, reason: 'unrecoverable')
    rescue StandardError => e
      ack_or_nak_action(msg, ctx, e)
    end

    def ack_or_nak_action(msg, ctx, error)
      max_deliver = JetstreamBridge.config.max_deliver.to_i
      if ctx.deliveries >= max_deliver
        # Only ACK if DLQ publish succeeds
        dlq_success = @dlq.publish(msg, ctx,
                                   reason: 'max_deliver_exceeded',
                                   error_class: error.class.name,
                                   error_message: error.message)

        if dlq_success
          Logging.warn(
            "DLQ (max_deliver) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
            "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
            tag: 'JetstreamBridge::Consumer'
          )
          ActionResult.new(action: :ack, ctx: ctx)
        else
          Logging.error(
            "DLQ publish failed at max_deliver, NAKing event_id=#{ctx.event_id} " \
            "seq=#{ctx.seq} deliveries=#{ctx.deliveries}",
            tag: 'JetstreamBridge::Consumer'
          )
          ActionResult.new(action: :nak, ctx: ctx, error: error,
                           delay: backoff_delay(ctx, error))
        end
      else
        Logging.warn(
          "NAK event_id=#{ctx.event_id} subject=#{ctx.subject} seq=#{ctx.seq} " \
          "deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
          tag: 'JetstreamBridge::Consumer'
        )
        ActionResult.new(action: :nak, ctx: ctx, error: error,
                         delay: backoff_delay(ctx, error))
      end
    end

    def dlq_action(msg, ctx, error, reason:)
      dlq_success = @dlq.publish(msg, ctx,
                                 reason: reason, error_class: error.class.name, error_message: error.message)
      if dlq_success
        Logging.warn(
          "DLQ (#{reason}) event_id=#{ctx.event_id} subject=#{ctx.subject} " \
          "seq=#{ctx.seq} deliveries=#{ctx.deliveries} err=#{error.class}: #{error.message}",
          tag: 'JetstreamBridge::Consumer'
        )
        ActionResult.new(action: :ack, ctx: ctx)
      else
        Logging.error(
          "DLQ publish failed (#{reason}), NAKing event_id=#{ctx.event_id}",
          tag: 'JetstreamBridge::Consumer'
        )
        ActionResult.new(action: :nak, ctx: ctx, error: error,
                         delay: backoff_delay(ctx, error))
      end
    end

    def apply_action(msg, action_result)
      return unless action_result

      case action_result.action
      when :ack
        msg.ack
        log_ack(action_result)
      when :nak
        safe_nak(msg, action_result.ctx, action_result.error, delay: action_result.delay)
      end
      action_result
    end

    def log_ack(result)
      ctx = result.ctx
      Logging.debug(
        "ACK event_id=#{ctx&.event_id} subject=#{ctx&.subject} seq=#{ctx&.seq} deliveries=#{ctx&.deliveries}",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def safe_nak(msg, ctx = nil, error = nil, delay: nil)
      # Use backoff strategy with error context if available
      if ctx && error && msg.respond_to?(:nak_with_delay)
        nak_delay = delay || @backoff.delay(ctx.deliveries.to_i, error)
        msg.nak_with_delay(nak_delay)
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

    def backoff_delay(ctx, error)
      return nil unless ctx && error

      @backoff.delay(ctx.deliveries.to_i, error)
    end
  end
end
