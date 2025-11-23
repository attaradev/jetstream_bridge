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

        {
          name: cfg.stream_name,
          exists: true,
          subjects: info.config.subjects,
          retention: info.config.retention,
          storage: info.config.storage,
          max_consumers: info.config.max_consumers,
          messages: info.state.messages,
          bytes: info.state.bytes,
          first_seq: info.state.first_seq,
          last_seq: info.state.last_seq
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
