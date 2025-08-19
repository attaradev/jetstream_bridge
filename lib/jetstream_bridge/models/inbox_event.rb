# frozen_string_literal: true

begin
  require 'active_record'
rescue LoadError
  # No-op; shim below if AR missing.
end

module JetstreamBridge
  # Default Inbox model when `use_inbox` is enabled.
  # Prefers event_id, but can fall back to (stream, stream_seq).
  if defined?(ActiveRecord::Base)
    class InboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_inbox_events'

      class << self
        def column?(name) = column_names.include?(name.to_s)

        def attribute_json?(name)
          return false unless respond_to?(:attribute_types) && attribute_types.key?(name.to_s)
          attribute_types[name.to_s].to_s.downcase.include?('json')
        end
      end

      if column?(:payload)
        serialize :payload, coder: JSON unless attribute_json?(:payload)
      end
      if column?(:headers)
        serialize :headers, coder: JSON unless attribute_json?(:headers)
      end

      if column?(:event_id)
        validates :event_id, presence: true, uniqueness: true
      elsif column?(:stream_seq)
        validates :stream_seq, presence: true
        validates :stream, presence: true, if: -> { self.class.column?(:stream) }
        if column?(:stream)
          validates :stream_seq, uniqueness: { scope: :stream }
        else
          validates :stream_seq, uniqueness: true
        end
      end

      validates :subject, presence: true, if: -> { self.class.column?(:subject) }

      if self.class.column?(:status)
        STATUSES = %w[received processing processed failed].freeze
        validates :status, inclusion: { in: STATUSES }
      end

      scope :processed, -> { where(status: 'processed') }, if: -> { column?(:status) }

      before_validation do
        self.status      ||= 'received' if self.class.column?(:status) && status.blank?
        self.received_at ||= Time.now.utc if self.class.column?(:received_at) && received_at.blank?
      end

      def processed?
        if self.class.column?(:processed_at)
          processed_at.present?
        elsif self.class.column?(:status)
          status == 'processed'
        else
          false
        end
      end

      def payload_hash
        v = self[:payload]
        case v
        when String then JSON.parse(v) rescue {}
        when Hash   then v
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

        def respond_to_missing?(_name, _priv = false) = false

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
