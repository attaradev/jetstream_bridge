# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative '../core/logging'

module JetstreamBridge
  # Handles parse → handler → ack / nak → DLQ
  class MessageProcessor
    def initialize(jts, handler)
      @jts = jts
      @handler = handler
    end

    def handle_message(msg)
      deliveries = msg.metadata&.num_delivered.to_i
      event_id   = msg.header&.[]('Nats-Msg-Id') || SecureRandom.uuid
      event      = parse_message(msg, event_id)
      return unless event

      process_event(msg, event, deliveries, event_id)
    end

    private

    def parse_message(msg, event_id)
      JSON.parse(msg.data)
    rescue JSON::ParserError => e
      publish_to_dlq!(msg)
      msg.ack
      Logging.warn("Malformed JSON to DLQ event_id=#{event_id}: #{e.message}",
                   tag: 'JetstreamBridge::Consumer')
      nil
    end

    def process_event(msg, event, deliveries, event_id)
      @handler.call(event, msg.subject, deliveries)
      msg.ack
    rescue StandardError => e
      ack_or_nak(msg, deliveries, event_id, e)
    end

    def ack_or_nak(msg, deliveries, event_id, error)
      if deliveries >= JetstreamBridge.config.max_deliver.to_i
        publish_to_dlq!(msg)
        msg.ack
        Logging.warn("Sent to DLQ after max_deliver event_id=#{event_id} err=#{error.message}",
                     tag: 'JetstreamBridge::Consumer')
      else
        msg.nak
        Logging.warn("NAK event_id=#{event_id} deliveries=#{deliveries} err=#{error.message}",
                     tag: 'JetstreamBridge::Consumer')
      end
    end

    def publish_to_dlq!(msg)
      return unless JetstreamBridge.config.use_dlq

      @jts.publish(JetstreamBridge.config.dlq_subject, msg.data, header: msg.header)
    rescue StandardError => e
      Logging.error("DLQ publish failed: #{e.class} #{e.message}",
                    tag: 'JetstreamBridge::Consumer')
    end
  end
end
