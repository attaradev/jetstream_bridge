# frozen_string_literal: true

require 'oj'

begin
  require 'active_record'
rescue LoadError
  # No-op; shim defined below.
end

module JetstreamBridge
  if defined?(ActiveRecord::Base)
    class OutboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_outbox_events'

      class << self
        # Safe column presence check that never boots a connection during class load.
        def has_column?(name)
          return false unless ar_connected?

          connection.schema_cache.columns_hash(table_name).key?(name.to_s)
        rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
          false
        end

        def ar_connected?
          # Avoid creating a connection; rescue if pool isn't set yet.
          ActiveRecord::Base.connected? && connection_pool.active_connection?
        rescue StandardError
          false
        end
      end

      # ---- Validations guarded by safe schema checks (no with_options) ----
      validates :payload,
                presence: true,
                if: -> { self.class.has_column?(:payload) }

      validates :event_id,
                presence: true,
                uniqueness: true,
                if: -> { self.class.has_column?(:event_id) }

      validates :resource_type,
                presence: true,
                if: -> { self.class.has_column?(:resource_type) }

      validates :resource_id,
                presence: true,
                if: -> { self.class.has_column?(:resource_id) }

      validates :event_type,
                presence: true,
                if: -> { self.class.has_column?(:event_type) }

      validates :subject,
                presence: true,
                if: -> { self.class.has_column?(:subject) }

      validates :attempts,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                if: -> { self.class.has_column?(:attempts) }

      # ---- Defaults that do not require schema at load time ----
      before_validation do
        now = Time.now.utc
        self.status ||= JetstreamBridge::Config::Status::PENDING if self.class.has_column?(:status) && status.blank?
        self.enqueued_at ||= now if self.class.has_column?(:enqueued_at) && enqueued_at.blank?
        self.attempts = 0 if self.class.has_column?(:attempts) && attempts.nil?
      end

      # ---- Query Scopes ----
      scope :pending, -> { where(status: JetstreamBridge::Config::Status::PENDING) if has_column?(:status) }
      scope :publishing, -> { where(status: JetstreamBridge::Config::Status::PUBLISHING) if has_column?(:status) }
      scope :sent, -> { where(status: JetstreamBridge::Config::Status::SENT) if has_column?(:status) }
      scope :failed, -> { where(status: JetstreamBridge::Config::Status::FAILED) if has_column?(:status) }
      scope :stale, lambda {
        pending.where('created_at < ?', 1.hour.ago) if has_column?(:created_at) && has_column?(:status)
      }
      scope :by_resource_type, lambda { |type|
        where(resource_type: type) if has_column?(:resource_type)
      }
      scope :by_event_type, lambda { |type|
        where(event_type: type) if has_column?(:event_type)
      }
      scope :recent, lambda { |limit = 100|
        order(created_at: :desc).limit(limit) if has_column?(:created_at)
      }

      # ---- Class Methods ----
      class << self
        # Retry failed events
        #
        # @param limit [Integer] Maximum number of events to retry
        # @return [Integer] Number of events reset for retry
        def retry_failed(limit: 100)
          return 0 unless has_column?(:status)

          failed.limit(limit).update_all(
            status: JetstreamBridge::Config::Status::PENDING,
            attempts: 0,
            last_error: nil
          )
        end

        # Clean up old sent events
        #
        # @param older_than [ActiveSupport::Duration] Age threshold
        # @return [Integer] Number of records deleted
        def cleanup_sent(older_than: 7.days)
          return 0 unless has_column?(:status) && has_column?(:sent_at)

          sent.where('sent_at < ?', older_than.ago).delete_all
        end
      end

      # ---- Instance Methods ----
      def mark_sent!
        now = Time.now.utc
        self.status  = JetstreamBridge::Config::Status::SENT if self.class.has_column?(:status)
        self.sent_at = now if self.class.has_column?(:sent_at)
        save!
      end

      def mark_failed!(err_msg)
        self.status     = JetstreamBridge::Config::Status::FAILED if self.class.has_column?(:status)
        self.last_error = err_msg if self.class.has_column?(:last_error)
        save!
      end

      def retry!
        return false unless self.class.has_column?(:status)

        update!(
          status: JetstreamBridge::Config::Status::PENDING,
          attempts: 0,
          last_error: nil
        )
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
        else
          v.respond_to?(:as_json) ? v.as_json : {}
        end
      end
    end
  else
    # Shim: loud failure if AR isn't present but someone calls the model.
    class OutboxEvent
      class << self
        def method_missing(method_name, *_args, &)
          raise_missing_ar!('Outbox', method_name)
        end

        def respond_to_missing?(_method_name, _include_private = false)
          false
        end

        private

        def raise_missing_ar!(which, method_name)
          raise(
            "#{which} requires ActiveRecord (tried to call ##{method_name}). " \
            "Enable `use_outbox` only in apps with ActiveRecord, or add " \
            "`gem \"activerecord\"` to your Gemfile."
          )
        end
      end
    end
  end
end
