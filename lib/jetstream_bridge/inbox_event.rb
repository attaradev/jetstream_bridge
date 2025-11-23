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
        # rubocop:disable Naming/PredicatePrefix
        def has_column?(name)
          return false unless ar_connected?

          connection.schema_cache.columns_hash(table_name).key?(name.to_s)
        rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
          false
        end
        # rubocop:enable Naming/PredicatePrefix

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
        self.status ||= 'received' if self.class.has_column?(:status) && status.blank?
        self.received_at ||= Time.now.utc if self.class.has_column?(:received_at) && received_at.blank?
      end

      # ---- Helpers ----
      def processed?
        if self.class.has_column?(:processed_at)
          processed_at.present?
        elsif self.class.has_column?(:status)
          status == 'processed'
        else
          false
        end
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
