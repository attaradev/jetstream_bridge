# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative '../core/connection'
require_relative '../core/duration'
require_relative '../core/logging'
require_relative '../core/config'
require_relative '../core/model_utils'
require_relative 'consumer_config'
require_relative 'message_processor'
require_relative 'subscription_manager'
require_relative 'inbox/inbox_processor'

module JetstreamBridge
  # Subscribes to "{env}.{dest}.sync.{app}" and processes messages.
  class Consumer
    DEFAULT_BATCH_SIZE = 25
    FETCH_TIMEOUT_SECS = 5
    IDLE_SLEEP_SECS    = 0.05

    def initialize(durable_name:, batch_size: DEFAULT_BATCH_SIZE, &block)
      @handler    = block
      @batch_size = batch_size
      @durable    = durable_name || JetstreamBridge.config.durable_name
      @jts        = Connection.connect!

      ensure_destination!

      @sub_mgr = SubscriptionManager.new(@jts, @durable, JetstreamBridge.config)
      @sub_mgr.ensure_consumer!
      @psub       = @sub_mgr.subscribe!

      @processor  = MessageProcessor.new(@jts, @handler)
      @inbox_proc = InboxProcessor.new(@processor) if JetstreamBridge.config.use_inbox
    end

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

    # Returns number of messages processed; 0 on timeout/idle or after recovery.
    def process_batch
      msgs = fetch_messages
      process_messages(msgs)
    rescue NATS::Timeout, NATS::IO::Timeout
      0
    rescue NATS::JetStream::Error => e
      handle_js_error(e)
    end

    # --- helpers ---

    def fetch_messages
      @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
    end

    def process_messages(msgs)
      msgs.sum { |m| process_one(m) }
    end

    def process_one(m)
      if @inbox_proc
        @inbox_proc.process(m) ? 1 : 0
      else
        @processor.handle_message(m)
        1
      end
    end

    def handle_js_error(e)
      if recoverable_consumer_error?(e)
        Logging.warn("Recovering subscription after error: #{e.class} #{e.message}",
                     tag: 'JetstreamBridge::Consumer')
        @sub_mgr.ensure_consumer!
        @psub = @sub_mgr.subscribe!
      else
        Logging.error("Fetch failed: #{e.class} #{e.message}",
                      tag: 'JetstreamBridge::Consumer')
      end
      0
    end

    def recoverable_consumer_error?(error)
      msg = error.message.to_s
      msg =~ /consumer.*(not\s+found|deleted)/i ||
        msg =~ /no\s+responders/i ||
        msg =~ /stream.*not\s+found/i
    end
  end
end
