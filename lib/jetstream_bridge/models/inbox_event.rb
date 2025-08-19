# frozen_string_literal: true

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

      # Validations guarded by safe checks
      if_condition = -> { self.class.has_column?(:event_id) }
      unless_condition = -> { !self.class.has_column?(:event_id) }

      validates :event_id, presence: true, uniqueness: true, if: if_condition

      with_options if: unless_condition do
        validates :stream_seq, presence: true, if: -> { self.class.has_column?(:stream_seq) }
        # uniqueness scoped to stream when both present
        if has_column?(:stream) && has_column?(:stream_seq)
          validates :stream_seq, uniqueness: { scope: :stream }
        elsif has_column?(:stream_seq)
          validates :stream_seq, uniqueness: true
        end
      end

      validates :subject, presence: true, if: -> { self.class.has_column?(:subject) }

      before_validation do
        self.status ||= 'received' if self.class.has_column?(:status) && status.blank?
        if self.class.has_column?(:received_at) && received_at.blank?
          self.received_at ||= Time.now.utc
        end
      end

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
          JSON.parse(v)
        rescue StandardError
          {}
        end
        when Hash then v
        else v.respond_to?(:as_json) ? v.as_json : {}
        end
      end
    end
  else
    class InboxEvent
      class << self
        def method_missing(method_name, *_args, &_block)
          raise_missing_ar!('Inbox', method_name)
        end

        def respond_to_missing?(_m, _p = false)
          false
        end

        private

        def raise_missing_ar!(which, method_name)
          raise(
            "#{which} requires ActiveRecord (tried to call ##{method_name}). " \
            'Enable `use_inbox` only in apps with ActiveRecord, or add ' \
            '`gem "activerecord"` to your Gemfile.'
          )
        end
      end
    end
  end
end
