# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'duration'
require_relative 'logging'

module JetstreamBridge
  # Subscribes to: data.sync.{dest}.{app}.>
  class Consumer
    DEFAULT_BATCH_SIZE = 25
    FETCH_TIMEOUT_SECS = 5

    def initialize(durable_name:, batch_size: DEFAULT_BATCH_SIZE, &block)
      @handler    = block
      @batch_size = batch_size
      @durable    = durable_name

      ensure_destination!
      @js = Connection.connect!
      ensure_consumer!
      subscribe!
    end

    def run!
      Logging.info('Consumer started…', tag: 'JetstreamBridge::Consumer')
      loop do
        msgs = @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
        msgs.each { |m| handle_message(m) }
      rescue NATS::Timeout
        # idle
      end
    end

    private

    def ensure_destination!
      raise ArgumentError, 'destination_app must be configured' if JetstreamBridge.config.destination_app.to_s.empty?
    end

    def filter_subject
      "#{JetstreamBridge.config.dest_subject}.>"
    end

    def ensure_consumer!
      stream = JetstreamBridge.config.stream_name
      @js.consumer_info(stream, @durable)
      Logging.info("Consumer #{@durable} exists.", tag: 'JetstreamBridge::Consumer')
    rescue NATS::JetStream::Error
      cfg = {
        durable_name: @durable,
        filter_subject: filter_subject,
        ack_policy: 'explicit',
        max_deliver: JetstreamBridge.config.max_deliver,
        ack_wait: Duration.to_millis(JetstreamBridge.config.ack_wait),
        backoff: Array(JetstreamBridge.config.backoff).map { |d| Duration.to_millis(d) }
      }
      @js.add_consumer(stream, **cfg)
      Logging.info("Created consumer #{@durable} (filter=#{filter_subject})", tag: 'JetstreamBridge::Consumer')
    end

    def subscribe!
      @psub = @js.pull_subscribe(
        filter_subject,
        @durable,
        stream: JetstreamBridge.config.stream_name,
        config: {
          ack_policy: 'explicit',
          max_deliver: JetstreamBridge.config.max_deliver,
          ack_wait: Duration.to_millis(JetstreamBridge.config.ack_wait),
          backoff: Array(JetstreamBridge.config.backoff).map { |d| Duration.to_millis(d) }
        }
      )
      Logging.info("Subscribed to #{filter_subject} (durable=#{@durable})", tag: 'JetstreamBridge::Consumer')
    end

    def handle_message(msg)
      deliveries = msg.metadata&.num_delivered.to_i
      event_id   = msg.header&.[]('Nats-Msg-Id') || SecureRandom.uuid

      begin
        event = JSON.parse(msg.data)
      rescue JSON::ParserError => e
        publish_to_dlq(msg)
        msg.ack
        Logging.warn("Malformed JSON to DLQ event_id=#{event_id}: #{e.message}", tag: 'JetstreamBridge::Consumer')
        return
      end

      begin
        @handler.call(event, msg.subject, deliveries)
        msg.ack
      rescue StandardError => e
        if deliveries >= JetstreamBridge.config.max_deliver.to_i
          publish_to_dlq(msg)
          msg.ack
          Logging.warn("Sent to DLQ after max_deliver event_id=#{event_id} err=#{e.message}",
                       tag: 'JetstreamBridge::Consumer')
        else
          msg.nak
          Logging.warn("NAK event_id=#{event_id} deliveries=#{deliveries} err=#{e.message}",
                       tag: 'JetstreamBridge::Consumer')
        end
      end
    end

    def publish_to_dlq(msg)
      return unless JetstreamBridge.config.use_dlq

      @js.publish(JetstreamBridge.config.dlq_subject, msg.data, header: msg.header)
    rescue StandardError => e
      Logging.error("DLQ publish failed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
    end
  end
end
