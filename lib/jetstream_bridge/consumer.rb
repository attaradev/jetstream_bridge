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
    DEFAULT_BATCH_SIZE   = 25
    FETCH_TIMEOUT_SECS   = 5
    IDLE_SLEEP_SECS      = 0.05

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

    # Starts the consumer loop.
    def run!
      Logging.info("Consumer #{@durable} started…", tag: 'JetstreamBridge::Consumer')
      loop do
        processed = process_batch
        sleep(IDLE_SLEEP_SECS) if processed.zero?
      end
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

    # Returns number of messages processed; 0 on timeout/idle or after recovery.
    def process_batch
      msgs = @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
      msgs.each { |m| @processor.handle_message(m) }
      msgs.size
    rescue NATS::Timeout, NATS::IO::Timeout
      0
    rescue NATS::JetStream::Error => e
      # Handle common recoverable states by re-ensuring consumer & subscription.
      if recoverable_consumer_error?(e)
        Logging.warn("Recovering subscription after error: #{e.class} #{e.message}",
                     tag: 'JetstreamBridge::Consumer')
        ensure_consumer!
        subscribe!
        0
      else
        Logging.error("Fetch failed: #{e.class} #{e.message}",
                      tag: 'JetstreamBridge::Consumer')
        0
      end
    end

    def recoverable_consumer_error?(error)
      msg = error.message.to_s
      msg =~ /consumer.*(not\s+found|deleted)/i ||
        msg =~ /no\s+responders/i
    end
  end
end
