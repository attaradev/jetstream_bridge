# frozen_string_literal: true

require 'oj'
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
  # Subscribes to destination subject and processes messages via a pull durable.
  class Consumer
    DEFAULT_BATCH_SIZE    = 25
    FETCH_TIMEOUT_SECS    = 5
    IDLE_SLEEP_SECS       = 0.05
    MAX_IDLE_BACKOFF_SECS = 1.0

    def initialize(durable_name: JetstreamBridge.config.durable_name,
                   batch_size: DEFAULT_BATCH_SIZE, &block)
      raise ArgumentError, 'handler block required' unless block_given?

      @handler       = block
      @batch_size    = Integer(batch_size)
      @durable       = durable_name
      @idle_backoff  = IDLE_SLEEP_SECS
      @running       = true
      @jts           = Connection.connect!

      ensure_destination!

      @sub_mgr = SubscriptionManager.new(@jts, @durable, JetstreamBridge.config)
      @processor  = MessageProcessor.new(@jts, @handler)
      @inbox_proc = InboxProcessor.new(@processor) if JetstreamBridge.config.use_inbox

      ensure_subscription!
    end

    def run!
      Logging.info(
        "Consumer #{@durable} started (batch=#{@batch_size}, dest=#{JetstreamBridge.config.destination_subject})…",
        tag: 'JetstreamBridge::Consumer'
      )
      while @running
        processed = process_batch
        idle_sleep(processed)
      end
    end

    # Allow external callers to stop a long-running loop gracefully.
    def stop!
      @running = false
    end

    private

    def ensure_destination!
      return unless JetstreamBridge.config.destination_app.to_s.empty?

      raise ArgumentError, 'destination_app must be configured'
    end

    def ensure_subscription!
      @sub_mgr.ensure_consumer!
      @psub = @sub_mgr.subscribe!
    end

    # Returns number of messages processed; 0 on timeout/idle or after recovery.
    def process_batch
      msgs = fetch_messages
      return 0 if msgs.nil? || msgs.empty?

      msgs.sum { |m| process_one(m) }
    rescue NATS::Timeout, NATS::IO::Timeout
      0
    rescue NATS::JetStream::Error => e
      handle_js_error(e)
    rescue StandardError => e
      Logging.error("Unexpected process_batch error: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      0
    end

    # --- helpers ---

    def fetch_messages
      @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
    end

    def process_one(msg)
      if @inbox_proc
        @inbox_proc.process(msg) ? 1 : 0
      else
        @processor.handle_message(msg)
        1
      end
    rescue StandardError => e
      # Safety: never let a single bad message kill the batch loop.
      Logging.error("Message processing crashed: #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      0
    end

    def handle_js_error(e)
      if recoverable_consumer_error?(e)
        Logging.warn(
          "Recovering subscription after error: #{e.class} #{e.message}",
          tag: 'JetstreamBridge::Consumer'
        )
        ensure_subscription!
      else
        Logging.error("Fetch failed (non-recoverable): #{e.class} #{e.message}", tag: 'JetstreamBridge::Consumer')
      end
      0
    end

    def recoverable_consumer_error?(error)
      msg = error.message.to_s
      code = js_err_code(msg)
      # Heuristics: consumer/stream missing, no responders, or common 404-ish cases
      msg =~ /consumer.*(not\s+found|deleted)/i ||
        msg =~ /no\s+responders/i ||
        msg =~ /stream.*not\s+found/i ||
        code == 404
    end

    def js_err_code(message)
      m = message.match(/err_code=(\d{3,5})/)
      m ? m[1].to_i : nil
    end

    def idle_sleep(processed)
      if processed.zero?
        # exponential-ish backoff with a tiny jitter to avoid sync across workers
        @idle_backoff = [@idle_backoff * 1.5, MAX_IDLE_BACKOFF_SECS].min
        sleep(@idle_backoff + (rand * 0.01))
      else
        @idle_backoff = IDLE_SLEEP_SECS
      end
    end
  end
end
