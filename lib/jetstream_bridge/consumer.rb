# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'connection'
require_relative 'duration'
require_relative 'logging'
require_relative 'consumer_config'
require_relative 'message_processor'
require_relative 'config'
require_relative 'model_utils'

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

    def desired_consumer_cfg
      ConsumerConfig.consumer_config(@durable, filter_subject)
    end

    def ensure_consumer!
      info = @jts.consumer_info(stream_name, @durable)
      if consumer_mismatch?(info, desired_consumer_cfg)
        Logging.warn(
          "Consumer #{@durable} exists with mismatched config; recreating (filter=#{filter_subject})",
          tag: 'JetstreamBridge::Consumer'
        )
        begin
          @jts.delete_consumer(stream_name, @durable)
        rescue NATS::JetStream::Error => e
          Logging.warn("Delete consumer #{@durable} ignored: #{e.class} #{e.message}",
                       tag: 'JetstreamBridge::Consumer')
        end
        @jts.add_consumer(stream_name, **desired_consumer_cfg)
        Logging.info("Created consumer #{@durable} (filter=#{filter_subject})",
                     tag: 'JetstreamBridge::Consumer')
      else
        Logging.info("Consumer #{@durable} exists with desired config.",
                     tag: 'JetstreamBridge::Consumer')
      end
    rescue NATS::JetStream::Error
      @jts.add_consumer(stream_name, **desired_consumer_cfg)
      Logging.info("Created consumer #{@durable} (filter=#{filter_subject})",
                   tag: 'JetstreamBridge::Consumer')
    end

    def consumer_mismatch?(info, desired_cfg)
      cfg = info.config
      (cfg.respond_to?(:filter_subject) ? cfg.filter_subject.to_s : cfg[:filter_subject].to_s) !=
        desired_cfg[:filter_subject].to_s
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
      count = 0
      msgs.each do |m|
        if JetstreamBridge.config.use_inbox
          count += (process_with_inbox(m) ? 1 : 0)
        else
          @processor.handle_message(m)
          count += 1
        end
      end
      count
    rescue NATS::Timeout, NATS::IO::Timeout
      0
    rescue NATS::JetStream::Error => e
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

    # ----- Inbox path -----
    def process_with_inbox(m)
      klass = ModelUtils.constantize(JetstreamBridge.config.inbox_model)

      unless ModelUtils.ar_class?(klass)
        Logging.warn("Inbox model #{klass} is not an ActiveRecord model; processing directly.",
                     tag: 'JetstreamBridge::Consumer')
        @processor.handle_message(m)
        return true
      end

      meta      = (m.respond_to?(:metadata) && m.metadata) || nil
      seq       = meta&.respond_to?(:stream_sequence) ? meta.stream_sequence : nil
      deliveries= meta&.respond_to?(:num_delivered)   ? meta.num_delivered   : nil
      subject   = m.subject.to_s
      headers   = (m.header || {})
      body_str  = m.data
      begin
        body = JSON.parse(body_str)
      rescue
        body = {}
      end

      event_id  = (headers['Nats-Msg-Id'] || body['event_id']).to_s.strip
      now       = Time.now.utc

      # Prefer event_id; fallback to the stream sequence (and subject) if the schema differs
      record = if ModelUtils.has_columns?(klass, :event_id)
                 klass.find_or_initialize_by(event_id: (event_id.presence || "seq:#{seq}"))
               elsif ModelUtils.has_columns?(klass, :stream_seq)
                 klass.find_or_initialize_by(stream_seq: seq)
               else
                 klass.new
               end

      # If already processed, just ACK and skip handler
      if record.respond_to?(:processed_at) && record.processed_at
        m.ack
        return true
      end

      # Create/update the inbox row before processing (idempotency + audit)
      ModelUtils.assign_known_attrs(record, {
        event_id:      (ModelUtils.has_columns?(klass, :event_id) ? (event_id.presence || "seq:#{seq}") : nil),
        subject:       subject,
        payload:       ModelUtils.json_dump(body.empty? ? body_str : body),
        headers:       ModelUtils.json_dump(headers),
        stream:        (ModelUtils.has_columns?(klass, :stream) ? meta&.stream : nil),
        stream_seq:    (ModelUtils.has_columns?(klass, :stream_seq) ? seq : nil),
        deliveries:    (ModelUtils.has_columns?(klass, :deliveries) ? deliveries : nil),
        status:        'processing',
        last_error:    nil,
        received_at:   (ModelUtils.has_columns?(klass, :received_at) ? (record.received_at || now) : nil),
        updated_at:    (ModelUtils.has_columns?(klass, :updated_at) ? now : nil)
      })
      record.save!

      # Hand off to your processor (expected to ack/nak on its own)
      @processor.handle_message(m)

      ModelUtils.assign_known_attrs(record, {
        status:       'processed',
        processed_at: (ModelUtils.has_columns?(klass, :processed_at) ? Time.now.utc : nil),
        updated_at:   (ModelUtils.has_columns?(klass, :updated_at) ? Time.now.utc : nil)
      })
      record.save!

      true
    rescue => e
      # Try to persist the failure state; allow JetStream redelivery policy to handle retries
      begin
        if record
          ModelUtils.assign_known_attrs(record, {
            status:     'failed',
            last_error: "#{e.class}: #{e.message}",
            updated_at: (ModelUtils.has_columns?(klass, :updated_at) ? Time.now.utc : nil)
          })
          record.save!
        end
      rescue => e2
        Logging.warn("Failed to persist inbox failure: #{e2.class}: #{e2.message}",
                     tag: 'JetstreamBridge::Consumer')
      end
      Logging.error("Inbox processing failed: #{e.class}: #{e.message}",
                    tag: 'JetstreamBridge::Consumer')
      # We do NOT ack here; let your MessageProcessor (or JS policy) handle redelivery/DLQ
      false
    end
    # ----- /Inbox path -----

    def recoverable_consumer_error?(error)
      msg = error.message.to_s
      msg =~ /consumer.*(not\s+found|deleted)/i ||
        msg =~ /no\s+responders/i ||
        msg =~ /stream.*not\s+found/i
    end
  end
end
