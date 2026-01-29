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
      record = if ModelUtils.has_columns?(@klass, :event_id)
                 @klass.find_or_initialize_by(event_id: msg.event_id)
               elsif ModelUtils.has_columns?(@klass, :stream_seq)
                 @klass.find_or_initialize_by(stream_seq: msg.seq)
               else
                 @klass.new
               end

      lock_record(record)
    end

    def already_processed?(record)
      record.respond_to?(:processed_at) && record.processed_at
    end

    def persist_pre(record, msg)
      ActiveRecord::Base.transaction do
        attrs = {
          event_id: msg.event_id,
          event_type: msg.body['type'] || msg.body['event_type'],
          resource_type: msg.body['resource_type'],
          resource_id: msg.body['resource_id'],
          subject: msg.subject,
          payload: ModelUtils.json_dump(msg.body_for_store),
          headers: ModelUtils.json_dump(msg.headers),
          stream: msg.stream,
          stream_seq: msg.seq,
          deliveries: msg.deliveries,
          status: 'processing',
          error_message: nil,          # Clear any previous error
          last_error: nil,             # Legacy field (for backwards compatibility)
          processing_attempts: (record.respond_to?(:processing_attempts) ? (record.processing_attempts || 0) + 1 : nil),
          received_at: record.respond_to?(:received_at) ? (record.received_at || msg.now) : nil,
          updated_at: record.respond_to?(:updated_at) ? msg.now : nil
        }
        # Some schemas capture the producing app
        attrs[:source_app] = msg.body['producer'] || msg.headers['producer'] if record.respond_to?(:source_app=)
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
        error_msg = "#{error.class}: #{error.message}"
        attrs = {
          status: 'failed',
          error_message: error_msg,   # Standard field name
          last_error: error_msg,      # Legacy field (for backwards compatibility)
          failed_at: record.respond_to?(:failed_at) ? now : nil,
          updated_at: record.respond_to?(:updated_at) ? now : nil
        }
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    rescue StandardError => e
      Logging.warn("Failed to persist inbox failure: #{e.class}: #{e.message}",
                   tag: 'JetstreamBridge::Consumer')
    end

    def lock_record(record)
      return record unless record.respond_to?(:persisted?) && record.persisted?
      return record unless record.respond_to?(:lock!)

      record.lock!
      record
    rescue ActiveRecord::RecordNotFound
      @klass.new
    end
  end
end
