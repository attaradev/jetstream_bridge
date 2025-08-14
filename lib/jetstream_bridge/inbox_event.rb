# frozen_string_literal: true

# If ActiveRecord is not available, a shim class is defined that raises
# a helpful error when used.
begin
  require 'active_record'
rescue LoadError
  # Ignore; we handle the lack of AR below.
end

module JetstreamBridge
  # InboxEvent is the default ActiveRecord model used by the gem when
  # `use_inbox` is enabled.
  # It records processed event IDs for idempotency.
  if defined?(ActiveRecord::Base)
    class InboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_inbox_events'

      validates :event_id, presence: true, uniqueness: true
      validates :subject,  presence: true
    end
  else
    # Shim that fails loudly if the app misconfigures the gem without AR.
    class InboxEvent
      class << self
        def method_missing(method_name, *_args, &_block)
          raise_missing_ar!('Inbox', method_name)
        end

        def respond_to_missing?(_method_name, _include_private = false)
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
