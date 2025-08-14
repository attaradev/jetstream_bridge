# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'duration'
require_relative 'logging'

module JetstreamBridge
  # Subscribes to `data.sync.{dest}.{app}.>` and processes messages.
  class Consumer
    DEFAULT_BATCH_SIZE = 25
    FETCH_TIMEOUT_SECS = 5

    # @param durable_name [String] Consumer name
    # @param batch_size [Integer] Max messages per fetch
    # @yield [event, subject, deliveries] Message handler
    def initialize(durable_name:, batch_size: DEFAULT_BATCH_SIZE, &block)
      @handler    = block
      @batch_size = batch_size
      @durable    = durable_name
      @jts        = Connection.connect!

      ensure_destination!
      ensure_consumer!
      subscribe!
    end

    # Starts the consumer loop.
    def run!
      Logging.info("Consumer #{@durable} started…", tag: 'JetstreamBridge::Consumer')
      loop { process_batch }
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
      @jts.consumer_info(stream, @durable)
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
      @jts.add_consumer(stream, **cfg)
      Logging.info("Created consumer #{@durable} (filter=#{filter_subject})", tag: 'JetstreamBridge::Consumer')
    end

    def subscribe!
      @psub = @jts.pull_subscribe(
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

    def process_batch
      msgs = @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
      msgs.each { |m| handle_message(m) }
    rescue NATS::Timeout
      # No messages available
    end

    def handle_message(msg)
      deliveries = msg.metadata&.num_delivered.to_i
      event_id   = msg.header&.[]('Nats-Msg-Id') || SecureRandom.uuid

      event = parse_message(msg, event_id)
      return unless event

      process_event(msg, event, deliveries, event_id)
    end

    def parse_message(msg, event_id)
      JSON.parse(msg.data)
    rescue JSON::ParserError => e
      publish_to_dlq(msg)
      msg.ack
      Logging.warn("Malformed JSON to DLQ event_id=#{event_id}: #{e.message}", tag: 'JetstreamBridge::Consumer')
      nil
    end

    def process_event(msg, event, deliveries, event_id)
      @handler.call(event, msg.subject, deliveries)
      msg.ack
    rescue StandardError => e
      if deliveries >= JetstreamBridge.config.max_deliver.to_i
        publish_to_dlq(msg)
        msg.ack
        Logging.warn(
          "Sent to DLQ after max_deliver event_id=#{event_id} err=#{e.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      else
        msg.nak
        Logging.warn(
          "NAK event_id=#{event_id} deliveries=#{deliveries} err=#{e.message}",
          tag: 'JetstreamBridge::Consumer'
        )
      end
    end

    def publish_to_dlq(msg)
      return unless JetstreamBridge.config.use_dlq
      @jts.publish(JetstreamBridge.config.dlq_subject, msg.data, header: msg.header)
    rescue StandardError => e
      Logging.error("DLQ publish failed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
    end
  end
end
