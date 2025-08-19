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
      ModelUtils.assign_known_attrs(record, {
                                      event_id: (if ModelUtils.has_columns?(@klass,
                                                                            :event_id)
                                                   msg.event_id
                                                 end),
                                      subject: msg.subject,
                                      payload: ModelUtils.json_dump(msg.body_for_store),
                                      headers: ModelUtils.json_dump(msg.headers),
                                      stream: (if ModelUtils.has_columns?(@klass,
                                                                          :stream)
                                                 msg.stream
                                               end),
                                      stream_seq: (if ModelUtils.has_columns?(@klass,
                                                                              :stream_seq)
                                                     msg.seq
                                                   end),
                                      deliveries: (if ModelUtils.has_columns?(@klass,
                                                                              :deliveries)
                                                     msg.deliveries
                                                   end),
                                      status: 'processing',
                                      last_error: nil,
                                      received_at: (if ModelUtils.has_columns?(@klass,
                                                                               :received_at)
                                                      record.received_at || msg.now
                                                    end),
                                      updated_at: (if ModelUtils.has_columns?(@klass,
                                                                              :updated_at)
                                                     msg.now
                                                   end)
                                    })
      record.save!
    end

    def persist_post(record)
      now = Time.now.utc
      ModelUtils.assign_known_attrs(record, {
                                      status: 'processed',
                                      processed_at: (if ModelUtils.has_columns?(@klass,
                                                                                :processed_at)
                                                       now
                                                     end),
                                      updated_at: (if ModelUtils.has_columns?(@klass,
                                                                              :updated_at)
                                                     now
                                                   end)
                                    })
      record.save!
    end

    def persist_failure(record, error)
      return unless record

      now = Time.now.utc
      ModelUtils.assign_known_attrs(record, {
                                      status: (if ModelUtils.has_columns?(@klass,
                                                                          :status)
                                                 'failed'
                                               end),
                                      last_error: (if ModelUtils.has_columns?(@klass,
                                                                              :last_error)
                                                     "#{error.class}: #{error.message}"
                                                   end),
                                      updated_at: (if ModelUtils.has_columns?(@klass,
                                                                              :updated_at)
                                                     now
                                                   end)
                                    })
      record.save!
    rescue StandardError => e
      Logging.warn("Failed to persist inbox failure: #{e.class}: #{e.message}",
                   tag: 'JetstreamBridge::Consumer')
    end
  end
end
