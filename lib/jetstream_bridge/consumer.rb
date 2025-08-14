# frozen_string_literal: true

require 'json'
require 'nats/io/client'
require 'securerandom'
require 'active_support/core_ext/string/inflections'

module JetstreamBridge
  # Durable pull consumer with retries, backoff, DLQ, optional Inbox idempotency.
  class Consumer
    DEFAULT_BATCH_SIZE  = 25
    FETCH_TIMEOUT_SECS  = 5
    IDLE_SLEEP_SECS     = 0.1
    RECONNECT_BACKOFFS  = [0.25, 1.0, 2.0, 5.0].freeze

    # Convert "30s", 30 (sec), "5000ms", 0.5, etc. to **milliseconds** (Integer)
    def self.to_millis(val)
      case val
      when Integer
        # Heuristic: small integers are seconds; big are already ms
        val >= 1_000 ? val : val * 1_000
      when Float
        (val * 1_000).round
      when String
        s = val.strip
        return s.to_i * 1_000 if s =~ /\A\d+\z/ # seconds

        if s =~ /\A(\d+(?:\.\d+)?)\s*(ms|s|m|h)\z/i
          qty  = Regexp.last_match(1).to_f
          unit = Regexp.last_match(2)&.downcase
          mult = { 'ms' => 1, 's' => 1_000, 'm' => 60_000, 'h' => 3_600_000 }[unit]
          return (qty * mult).round
        end
        raise ArgumentError, "invalid duration: #{val.inspect}"
      else
        return (val.to_f * 1_000).round if val.respond_to?(:to_f)

        raise ArgumentError, "invalid duration type: #{val.class}"
      end
    end

    def initialize(durable_name:, source_filter: nil, batch_size: DEFAULT_BATCH_SIZE, &block)
      @handler     = block
      @batch_size  = batch_size
      # If source_filter not given, default to the configured destination_app (i.e., the peer we read FROM)
      @source      = source_filter || JetstreamBridge.config.destination_app
      if @source.to_s.empty?
        raise ArgumentError,
              'source_filter is required (or set JetstreamBridge.config.destination_app)'
      end

      @durable     = durable_name
      @running     = true

      connect!
      subscribe!

      trap('INT')  { shutdown }
      trap('TERM') { shutdown }
    end

    def run!
      log(:info, "Consumer started (source=#{@source}, durable=#{@durable})…")
      while @running
        begin
          msgs = @psub.fetch(@batch_size, timeout: FETCH_TIMEOUT_SECS)
          msgs.each { |m| handle_message(m) }
        rescue NATS::Timeout
          sleep IDLE_SLEEP_SECS
          next
        rescue NATS::IO::Error, NATS::IO::Timeout, NATS::IO::SocketError => e
          log(:warn, "Fetch transport error: #{e.class} #{e.message} — reconnecting")
          reconnect_and_resubscribe!
        rescue StandardError => e
          log(:error, "Fetch error: #{e.class} #{e.message}")
          sleep 1
        end
      end
    ensure
      close
    end

    private

    def connect!
      urls = (JetstreamBridge.config.nats_urls || 'nats://localhost:4222')
             .to_s.split(',').map(&:strip).reject(&:empty?)
      raise 'No NATS URLs configured' if urls.empty?

      @nc&.close
      @nc = NATS::IO::Client.new
      @nc.connect(servers: urls)
      @js = @nc.jetstream
    end

    def subscribe!
      subject_filter = "#{JetstreamBridge.config.env}.data.sync.#{@source}.>"
      @psub = @js.pull_subscribe(
        subject_filter,
        @durable,
        stream: JetstreamBridge.config.stream_name,
        config: {
          'ack_policy' => 'explicit',
          'max_deliver' => JetstreamBridge.config.max_deliver,
          # IMPORTANT: nats-pure expects ms here (the client converts to ns for server)
          'ack_wait' => Consumer.to_millis(JetstreamBridge.config.ack_wait),
          'backoff' => Array(JetstreamBridge.config.backoff).map { |d| Consumer.to_millis(d) }
        }
      )
      log(:info, "Subscribed to #{subject_filter} (durable=#{@durable})")
    end

    def reconnect_and_resubscribe!
      attempts = 0
      begin
        connect!
        subscribe!
      rescue StandardError => e
        delay = RECONNECT_BACKOFFS.fetch(attempts, RECONNECT_BACKOFFS.last)
        log(:warn, "Reconnect attempt #{attempts + 1} failed: #{e.class} #{e.message} — retrying in #{delay}s")
        sleep delay
        attempts += 1
        retry if @running
      end
    end

    def handle_message(msg)
      deliveries = msg.metadata&.num_delivered.to_i
      event_id   = msg.header&.[]('Nats-Msg-Id') || SecureRandom.uuid

      if JetstreamBridge.config.use_inbox &&
         JetstreamBridge.config.inbox_model.constantize.exists?(event_id: event_id)
        msg.ack
        return
      end

      begin
        event = JSON.parse(msg.data)
      rescue JSON::ParserError => e
        # Malformed JSON → DLQ immediately (avoid endless redeliveries)
        publish_to_dlq(msg)
        msg.ack
        log(:warn, "Malformed JSON sent to DLQ event_id=#{event_id}: #{e.message}")
        return
      end

      begin
        @handler.call(event, msg.subject, deliveries)

        if JetstreamBridge.config.use_inbox
          JetstreamBridge.config.inbox_model.constantize.create!(
            event_id: event_id,
            subject: msg.subject,
            processed_at: Time.current
          )
        end

        msg.ack
      rescue StandardError => e
        if deliveries >= JetstreamBridge.config.max_deliver.to_i
          publish_to_dlq(msg)
          msg.ack
          log(:warn, "Sent to DLQ after max_deliver event_id=#{event_id} err=#{e.message}")
        else
          msg.nak
          log(:warn, "NAK event_id=#{event_id} deliveries=#{deliveries} err=#{e.message}")
        end
      end
    end

    def publish_to_dlq(msg)
      @nc.publish(JetstreamBridge.config.dlq_subject, msg.data, header: msg.header)
    rescue StandardError => e
      log(:error, "DLQ publish failed: #{e.class} #{e.message}")
    end

    def shutdown
      return unless @running

      @running = false
      log(:info, 'Consumer shutting down…')
    end

    def close
      @nc&.close
    rescue StandardError
      # swallow close errors
    ensure
      @nc = @js = @psub = nil
    end

    def log(level, msg)
      if defined?(Rails)
        Rails.logger.public_send(level, "[JetstreamBridge::Consumer] #{msg}")
      else
        puts(msg)
      end
    end
  end
end
