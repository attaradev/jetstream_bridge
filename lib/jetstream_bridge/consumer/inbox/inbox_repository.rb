# frozen_string_literal: true

require_relative '../../core/model_utils'
require_relative '../../core/logging'

module JetstreamBridge
  # AR-facing operations for inbox rows (find/build/persist).
  class InboxRepository
    def initialize(klass)
      @klass = klass
    end

    def find_or_build(msg)
      if ModelUtils.has_columns?(@klass, :event_id)
        @klass.find_or_initialize_by(event_id: msg.event_id)
      elsif ModelUtils.has_columns?(@klass, :stream_seq)
        @klass.find_or_initialize_by(stream_seq: msg.seq)
      else
        @klass.new
      end
    end

    def already_processed?(record)
      record.respond_to?(:processed_at) && record.processed_at
    end

    def persist_pre(record, msg)
      ActiveRecord::Base.transaction do
        attrs = {
          event_id: msg.event_id,
          subject: msg.subject,
          payload: ModelUtils.json_dump(msg.body_for_store),
          headers: ModelUtils.json_dump(msg.headers),
          stream: msg.stream,
          stream_seq: msg.seq,
          deliveries: msg.deliveries,
          status: 'processing',
          last_error: nil,
          received_at: record.respond_to?(:received_at) ? (record.received_at || msg.now) : nil,
          updated_at: record.respond_to?(:updated_at) ? msg.now : nil
        }
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    end

    def persist_post(record)
      ActiveRecord::Base.transaction do
        now = Time.now.utc
        attrs = {
          status: 'processed',
          processed_at: record.respond_to?(:processed_at) ? now : nil,
          updated_at: record.respond_to?(:updated_at) ? now : nil
        }
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    end

    def persist_failure(record, error)
      return unless record

      ActiveRecord::Base.transaction do
        now = Time.now.utc
        attrs = {
          status: 'failed',
          last_error: "#{error.class}: #{error.message}",
          updated_at: record.respond_to?(:updated_at) ? now : nil
        }
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    rescue StandardError => e
      Logging.warn("Failed to persist inbox failure: #{e.class}: #{e.message}",
                   tag: 'JetstreamBridge::Consumer')
    end
  end
end
