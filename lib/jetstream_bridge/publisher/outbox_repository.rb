# frozen_string_literal: true

require_relative '../core/model_utils'
require_relative '../core/logging'

module JetstreamBridge
  # Encapsulates AR-backed outbox persistence operations.
  class OutboxRepository
    def initialize(klass)
      @klass = klass
    end

    def find_or_build(event_id)
      record = ModelUtils.find_or_init_by_best(
        @klass,
        { event_id: event_id },
        { dedup_key: event_id } # fallback if app uses a different unique column
      )

      # Lock the row to prevent concurrent processing
      if record.persisted? && !record.new_record? && record.respond_to?(:lock!)
        begin
          record.lock!
        rescue ActiveRecord::RecordNotFound
          # Record was deleted between find and lock, create new
          record = @klass.new
        end
      end

      record
    end

    def already_sent?(record)
      (record.respond_to?(:sent_at) && record.sent_at) ||
        (record.respond_to?(:status) && record.status == 'sent')
    end

    def persist_pre(record, subject, envelope)
      ActiveRecord::Base.transaction do
        now      = Time.now.utc
        event_id = envelope['event_id'].to_s

        attrs = {
          event_id: event_id,
          subject: subject,
          payload: ModelUtils.json_dump(envelope),
          headers: ModelUtils.json_dump({ 'nats-msg-id' => event_id }),
          status: 'publishing',
          last_error: nil
        }
        attrs[:attempts] = 1 + (record.attempts || 0) if record.respond_to?(:attempts)
        attrs[:enqueued_at] = (record.enqueued_at || now) if record.respond_to?(:enqueued_at)
        attrs[:updated_at] = now if record.respond_to?(:updated_at)

        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    end

    def persist_success(record)
      ActiveRecord::Base.transaction do
        now = Time.now.utc
        attrs = { status: 'sent' }
        attrs[:sent_at] = now if record.respond_to?(:sent_at)
        attrs[:updated_at] = now if record.respond_to?(:updated_at)
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    end

    def persist_failure(record, message)
      ActiveRecord::Base.transaction do
        now = Time.now.utc
        attrs = { status: 'failed', last_error: message }
        attrs[:updated_at] = now if record.respond_to?(:updated_at)
        ModelUtils.assign_known_attrs(record, attrs)
        record.save!
      end
    end

    def persist_exception(record, error)
      return unless record

      persist_failure(record, "#{error.class}: #{error.message}")
    rescue StandardError => e
      Logging.warn("Failed to persist outbox failure: #{e.class}: #{e.message}",
                   tag: 'JetstreamBridge::Publisher')
    end
  end
end
