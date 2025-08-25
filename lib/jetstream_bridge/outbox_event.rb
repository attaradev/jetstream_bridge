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

      # Preferred path when event_id exists
      validates :event_id,
                presence: true,
                uniqueness: true,
                if: -> { self.class.has_column?(:event_id) }

      # Fallback legacy fields when event_id is absent
      validates :resource_type,
                presence: true,
                if: lambda {
                  !self.class.has_column?(:event_id) && self.class.has_column?(:resource_type)
                }

      validates :resource_id,
                presence: true,
                if: lambda {
                  !self.class.has_column?(:event_id) && self.class.has_column?(:resource_id)
                }

      validates :event_type,
                presence: true,
                if: -> { !self.class.has_column?(:event_id) && self.class.has_column?(:event_type) }

      validates :subject,
                presence: true,
                if: -> { self.class.has_column?(:subject) }

      validates :attempts,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                if: -> { self.class.has_column?(:attempts) }

      # ---- Defaults that do not require schema at load time ----
      before_validation do
        now = Time.now.utc
        self.status ||= 'pending' if self.class.has_column?(:status) && status.blank?
        self.enqueued_at ||= now if self.class.has_column?(:enqueued_at) && enqueued_at.blank?
        self.attempts = 0 if self.class.has_column?(:attempts) && attempts.nil?
      end

      # ---- Helpers ----
      def mark_sent!
        now = Time.now.utc
        self.status  = 'sent' if self.class.has_column?(:status)
        self.sent_at = now    if self.class.has_column?(:sent_at)
        save!
      end

      def mark_failed!(err_msg)
        self.status     = 'failed' if self.class.has_column?(:status)
        self.last_error = err_msg  if self.class.has_column?(:last_error)
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
        else
          v.respond_to?(:as_json) ? v.as_json : {}
        end
      end
    end
  else
    # Shim: loud failure if AR isn't present but someone calls the model.
    class OutboxEvent
      class << self
        def method_missing(method_name, *_args, &_block)
          raise_missing_ar!('Outbox', method_name)
        end

        def respond_to_missing?(_m, _p = false)
          false
        end

        private

        def raise_missing_ar!(which, method_name)
          raise(
            "#{which} requires ActiveRecord (tried to call ##{method_name}). " \
            'Enable `use_outbox` only in apps with ActiveRecord, or add ' \
            '`gem "activerecord"` to your Gemfile.'
          )
        end
      end
    end
  end
end
