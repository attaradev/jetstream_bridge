# frozen_string_literal: true

require_relative 'logging'

module JetstreamBridge
  # Debug helper for troubleshooting JetStream Bridge operations
  module DebugHelper
    class << self
      # Print comprehensive debug information about the current setup
      def debug_info
        info = {
          config: config_debug,
          connection: connection_debug,
          stream: stream_debug,
          health: JetstreamBridge.health_check
        }

        Logging.info('=== JetStream Bridge Debug Info ===', tag: 'JetstreamBridge::Debug')
        info.each do |section, data|
          Logging.info("#{section.to_s.upcase}:", tag: 'JetstreamBridge::Debug')
          log_hash(data, indent: 2)
        end
        Logging.info('=== End Debug Info ===', tag: 'JetstreamBridge::Debug')

        info
      end

      private

      def config_debug
        cfg = JetstreamBridge.config
        {
          env: cfg.env,
          app_name: cfg.app_name,
          destination_app: cfg.destination_app,
          stream_name: cfg.stream_name,
          source_subject: begin
            cfg.source_subject
          rescue StandardError
            'ERROR'
          end,
          destination_subject: begin
            cfg.destination_subject
          rescue StandardError
            'ERROR'
          end,
          dlq_subject: begin
            cfg.dlq_subject
          rescue StandardError
            'ERROR'
          end,
          durable_name: cfg.durable_name,
          nats_urls: cfg.nats_urls,
          max_deliver: cfg.max_deliver,
          ack_wait: cfg.ack_wait,
          backoff: cfg.backoff,
          use_outbox: cfg.use_outbox,
          use_inbox: cfg.use_inbox,
          use_dlq: cfg.use_dlq,
          outbox_model: cfg.outbox_model,
          inbox_model: cfg.inbox_model
        }
      end

      def connection_debug
        conn = Connection.instance
        {
          connected: conn.connected?,
          connected_at: conn.connected_at&.iso8601,
          nc_present: !conn.instance_variable_get(:@nc).nil?,
          jts_present: !conn.instance_variable_get(:@jts).nil?
        }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      def stream_debug
        return { error: 'Not connected' } unless Connection.instance.connected?

        jts = Connection.jetstream
        cfg = JetstreamBridge.config
        info = jts.stream_info(cfg.stream_name)

        # Handle both object-style and hash-style access for compatibility
        config_data = info.config
        state_data = info.state
        subjects = config_data.respond_to?(:subjects) ? config_data.subjects : config_data[:subjects]
        retention = config_data.respond_to?(:retention) ? config_data.retention : config_data[:retention]
        storage = config_data.respond_to?(:storage) ? config_data.storage : config_data[:storage]
        max_consumers = config_data.respond_to?(:max_consumers) ? config_data.max_consumers : config_data[:max_consumers]
        messages = state_data.respond_to?(:messages) ? state_data.messages : state_data[:messages]
        bytes = state_data.respond_to?(:bytes) ? state_data.bytes : state_data[:bytes]
        first_seq = state_data.respond_to?(:first_seq) ? state_data.first_seq : state_data[:first_seq]
        last_seq = state_data.respond_to?(:last_seq) ? state_data.last_seq : state_data[:last_seq]

        {
          name: cfg.stream_name,
          exists: true,
          subjects: subjects,
          retention: retention,
          storage: storage,
          max_consumers: max_consumers,
          messages: messages,
          bytes: bytes,
          first_seq: first_seq,
          last_seq: last_seq
        }
      rescue StandardError => e
        {
          name: JetstreamBridge.config.stream_name,
          exists: false,
          error: "#{e.class}: #{e.message}"
        }
      end

      def log_hash(hash, indent: 0)
        prefix = ' ' * indent
        hash.each do |key, value|
          if value.is_a?(Hash)
            Logging.info("#{prefix}#{key}:", tag: 'JetstreamBridge::Debug')
            log_hash(value, indent: indent + 2)
          elsif value.is_a?(Array)
            Logging.info("#{prefix}#{key}: #{value.inspect}", tag: 'JetstreamBridge::Debug')
          else
            Logging.info("#{prefix}#{key}: #{value}", tag: 'JetstreamBridge::Debug')
          end
        end
      end
    end
  end
end
