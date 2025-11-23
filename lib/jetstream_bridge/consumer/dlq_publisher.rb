# frozen_string_literal: true

require 'oj'
require 'time'
require_relative '../core/logging'

module JetstreamBridge
  class DlqPublisher
    def initialize(jts)
      @jts = jts
    end

    # Sends original payload to DLQ with explanatory headers/context
    # @return [Boolean] true if published successfully, false otherwise
    def publish(msg, ctx, reason:, error_class:, error_message:)
      return true unless JetstreamBridge.config.use_dlq

      envelope = build_envelope(ctx, reason, error_class, error_message)
      headers  = build_headers(msg.header, reason, ctx.deliveries, envelope)
      @jts.publish(JetstreamBridge.config.dlq_subject, msg.data, header: headers)
      true
    rescue StandardError => e
      Logging.error(
        "DLQ publish failed event_id=#{ctx.event_id}: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
      false
    end

    private

    def build_envelope(ctx, reason, error_class, error_message)
      {
        event_id: ctx.event_id,
        reason: reason,
        error_class: error_class,
        error_message: error_message,
        deliveries: ctx.deliveries,
        original_subject: ctx.subject,
        sequence: ctx.seq,
        consumer: ctx.consumer,
        stream: ctx.stream,
        published_at: Time.now.utc.iso8601
      }
    end

    def build_headers(original_headers, reason, deliveries, envelope)
      headers = (original_headers || {}).dup
      headers['x-dead-letter'] = 'true'
      headers['x-dlq-reason']  = reason
      headers['x-deliveries']  = deliveries.to_s
      headers['x-dlq-context'] = Oj.dump(envelope, mode: :compat)
      headers
    end
  end
end
