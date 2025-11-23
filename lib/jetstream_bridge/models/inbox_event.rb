# frozen_string_literal: true

require 'oj'

begin
  require 'active_record'
rescue LoadError
  # No-op; shim defined below.
end

module JetstreamBridge
  if defined?(ActiveRecord::Base)
    class InboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_inbox_events'

      class << self
        # Safe column presence check that never boots a connection during class load.
        def has_column?(name)
          return false unless ar_connected?

          connection.schema_cache.columns_hash(table_name).key?(name.to_s)
        rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
          false
        end

        def ar_connected?
          ActiveRecord::Base.connected? && connection_pool.active_connection?
        rescue StandardError
          false
        end
      end

      # ---- Validations (NO with_options; guard everything with procs) ----

      # Preferred dedupe key
      validates :event_id,
                presence: true,
                uniqueness: true,
                if: -> { self.class.has_column?(:event_id) }

      # Fallback to (stream, stream_seq) when event_id column not present
      validates :stream_seq,
                presence: true,
                if: -> { !self.class.has_column?(:event_id) && self.class.has_column?(:stream_seq) }

      validates :stream_seq,
                uniqueness: { scope: :stream },
                if: lambda {
                  !self.class.has_column?(:event_id) &&
                    self.class.has_column?(:stream_seq) &&
                    self.class.has_column?(:stream)
                }

      validates :stream_seq,
                uniqueness: true,
                if: lambda {
                  !self.class.has_column?(:event_id) &&
                    self.class.has_column?(:stream_seq) &&
                    !self.class.has_column?(:stream)
                }

      validates :subject,
                presence: true,
                if: -> { self.class.has_column?(:subject) }

      # ---- Defaults that do not require schema at load time ----
      before_validation do
        self.status ||= JetstreamBridge::Config::Status::RECEIVED if self.class.has_column?(:status) && status.blank?
        self.received_at ||= Time.now.utc if self.class.has_column?(:received_at) && received_at.blank?
      end

      # ---- Query Scopes ----
      scope :received, -> { where(status: JetstreamBridge::Config::Status::RECEIVED) if has_column?(:status) }
      scope :processing, -> { where(status: JetstreamBridge::Config::Status::PROCESSING) if has_column?(:status) }
      scope :processed, -> { where(status: JetstreamBridge::Config::Status::PROCESSED) if has_column?(:status) }
      scope :failed, -> { where(status: JetstreamBridge::Config::Status::FAILED) if has_column?(:status) }
      scope :by_subject, lambda { |subject|
        where(subject: subject) if has_column?(:subject)
      }
      scope :by_stream, lambda { |stream|
        where(stream: stream) if has_column?(:stream)
      }
      scope :recent, lambda { |limit = 100|
        order(received_at: :desc).limit(limit) if has_column?(:received_at)
      }
      scope :unprocessed, lambda {
        where.not(status: JetstreamBridge::Config::Status::PROCESSED) if has_column?(:status)
      }

      # ---- Class Methods ----
      class << self
        # Clean up old processed events
        #
        # @param older_than [ActiveSupport::Duration] Age threshold
        # @return [Integer] Number of records deleted
        def cleanup_processed(older_than: 30.days)
          return 0 unless has_column?(:status) && has_column?(:processed_at)

          processed.where('processed_at < ?', older_than.ago).delete_all
        end

        # Get processing statistics
        #
        # Uses a single aggregated query to avoid N+1 problem.
        #
        # @return [Hash] Statistics hash with counts by status
        def processing_stats
          return {} unless has_column?(:status)

          # Single aggregated query instead of 4 separate queries
          stats_by_status = group(:status).count
          total_count = stats_by_status.values.sum

          {
            total: total_count,
            processed: stats_by_status['processed'] || 0,
            failed: stats_by_status['failed'] || 0,
            pending: stats_by_status['pending'] || stats_by_status[nil] || 0
          }
        end
      end

      # ---- Instance Methods ----
      def processed?
        if self.class.has_column?(:processed_at)
          processed_at.present?
        elsif self.class.has_column?(:status)
          status == JetstreamBridge::Config::Status::PROCESSED
        else
          false
        end
      end

      def mark_processed!
        now = Time.now.utc
        self.status = JetstreamBridge::Config::Status::PROCESSED if self.class.has_column?(:status)
        self.processed_at = now if self.class.has_column?(:processed_at)
        save!
      end

      def mark_failed!(err_msg)
        self.status = JetstreamBridge::Config::Status::FAILED if self.class.has_column?(:status)
        self.last_error = err_msg if self.class.has_column?(:last_error)
        save!
      end

      def payload_hash
        v = self[:payload]
        case v
        when String then begin
          Oj.load(v, mode: :strict)
        rescue Oj::Error
          {}
        end
        when Hash then v
        else v.respond_to?(:as_json) ? v.as_json : {}
        end
      end
    end
  else
    # Shim: loud failure if AR isn't present but someone calls the model.
    class InboxEvent
      class << self
        def method_missing(method_name, *_args, &)
          raise_missing_ar!('Inbox', method_name)
        end

        def respond_to_missing?(_method_name, _include_private = false)
          false
        end

        private

        def raise_missing_ar!(which, method_name)
          raise(
            "#{which} requires ActiveRecord (tried to call ##{method_name}). " \
            "Enable `use_inbox` only in apps with ActiveRecord, or add " \
            "`gem \"activerecord\"` to your Gemfile."
          )
        end
      end
    end
  end
end
