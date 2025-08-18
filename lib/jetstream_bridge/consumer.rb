# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'duration'
require_relative 'logging'
require_relative 'consumer_config'
require_relative 'message_processor'
require_relative 'config'

module JetstreamBridge
  # Subscribes to "{env}.data.sync.{dest}.{app}" and processes messages.
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
      @processor = MessageProcessor.new(@jts, @handler)
    end

    def run!
      Logging.info("Consumer #{@durable} started…", tag: 'JetstreamBridge::Consumer')
      loop { process_batch }
    end

    private

    def ensure_destination!
      return unless JetstreamBridge.config.destination_app.to_s.empty?
      raise ArgumentError, 'destination_app must be configured'
    end

    def stream_name
      JetstreamBridge.config.stream_name
    end

    def filter_subject
      JetstreamBridge.config.destination_subject
    end

    def ensure_consumer!
      @jts.consumer_info(stream_name, @durable)
      Logging.info("Consumer #{@durable} exists.", tag: 'JetstreamBridge::Consumer')
    rescue NATS::JetStream::Error
      @jts.add_consumer(stream_name, **ConsumerConfig.consumer_config(@durable, filter_subject))
      Logging.info("Created consumer #{@durable} (filter=#{filter_subject})",
                   tag: 'JetstreamBridge::Consumer')
    end

    def subscribe!
      @psub = @jts.pull_subscribe(
        filter_subject,
        @durable,
        stream: stream_name,
        config: ConsumerConfig.subscribe_config
      )
      Logging.info("Subscribed to #{filter_subject} (durable=#{@durable})",
                   tag: 'JetstreamBridge::Consumer')
    end

    def process_batch
      fetch_messages.each { |m| @processor.handle_message(m) }
    rescue NATS::Timeout
      # nothing in this window
    end

    def fetch_messages
      @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
    end
  end
end
