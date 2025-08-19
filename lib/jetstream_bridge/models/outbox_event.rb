# frozen_string_literal: true

begin
  require 'active_record'
rescue LoadError
  # No-op; we provide a shim below if AR is missing.
end

module JetstreamBridge
  # Default Outbox model when `use_outbox` is enabled.
  # Works with event-centric columns and stays compatible with legacy resource_* fields.
  if defined?(ActiveRecord::Base)
    class OutboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_outbox_events'

      class << self
        def column?(name) = column_names.include?(name.to_s)

        def attribute_json?(name)
          return false unless respond_to?(:attribute_types) && attribute_types.key?(name.to_s)
          attribute_types[name.to_s].to_s.downcase.include?('json')
        end
      end

      # JSON casting fallback if column is text
      if column?(:payload)
        serialize :payload, coder: JSON unless attribute_json?(:payload)
      end
      if column?(:headers)
        serialize :headers, coder: JSON unless attribute_json?(:headers)
      end

      # Validations (guarded by column existence)
      validates :payload, presence: true, if: -> { self.class.column?(:payload) }

      if self.class.column?(:event_id)
        validates :event_id, presence: true, uniqueness: true
      else
        validates :resource_type, presence: true, if: -> { self.class.column?(:resource_type) }
        validates :resource_id,   presence: true, if: -> { self.class.column?(:resource_id) }
        validates :event_type,    presence: true, if: -> { self.class.column?(:event_type) }
      end

      validates :subject, presence: true, if: -> { self.class.column?(:subject) }

      if self.class.column?(:status)
        STATUSES = %w[pending publishing sent failed].freeze
        validates :status, inclusion: { in: STATUSES }
      end

      if self.class.column?(:attempts)
        validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      end

      # Scopes (optional)
      scope :pending,       -> { where(status: 'pending') },        if: -> { column?(:status) }
      scope :publishing,    -> { where(status: 'publishing') },     if: -> { column?(:status) }
      scope :failed,        -> { where(status: 'failed') },         if: -> { column?(:status) }
      scope :sent,          -> { where(status: 'sent') },           if: -> { column?(:status) }
      scope :ready_to_send, -> { where(status: %w[pending failed]) }, if: -> { column?(:status) }

      before_validation do
        now = Time.now.utc
        self.status     ||= 'pending' if self.class.column?(:status)     && status.blank?
        self.enqueued_at ||= now      if self.class.column?(:enqueued_at) && enqueued_at.blank?
        self.attempts     = 0         if self.class.column?(:attempts)   && attempts.nil?
      end

      # Helpers (no-ops if columns missing)
      def mark_sent!
        now = Time.now.utc
        self.status  = 'sent' if self.class.column?(:status)
        self.sent_at = now    if self.class.column?(:sent_at)
        save!
      end

      def mark_failed!(err_msg)
        self.status     = 'failed' if self.class.column?(:status)
        self.last_error = err_msg  if self.class.column?(:last_error)
        save!
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
    # Shim: friendly error if AR is not available.
    class OutboxEvent
      class << self
        def method_missing(method_name, *_args, &_block)
          raise_missing_ar!('Outbox', method_name)
        end

        def respond_to_missing?(_name, _priv = false) = false

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
