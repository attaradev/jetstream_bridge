# frozen_string_literal: true

# If ActiveRecord is not available, a shim class is defined that raises
# a helpful error when used.
begin
  require 'active_record'
rescue LoadError
  # Ignore; we handle the lack of AR below.
end

# OutboxEvent is the default ActiveRecord model used by the gem when
# `use_outbox` is enabled.
# It stores pending events that will be flushed
# to NATS JetStream by your worker/cron.
module JetstreamBridge
  if defined?(ActiveRecord::Base)
    # ActiveRecord model for Outbox events.
    class OutboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_outbox_events'

      # Prefer native JSON/JSONB column.
      # If the column is text, `serialize` with JSON keeps backward compatibility.
      if respond_to?(:attribute_types) && attribute_types.key?('payload') &&
         attribute_types['payload'].type.in?(%i[json jsonb])
        # No-op: AR already gives JSON casting.
      else
        serialize :payload, coder: JSON
      end

      # Minimal validations that are generally useful; keep them short.
      validates :resource_type, presence: true
      validates :resource_id,   presence: true
      validates :event_type,    presence: true
      validates :payload,       presence: true
    end
  else
    # Shim that fails loudly if the app misconfigures the gem without AR.
    class OutboxEvent
      class << self
        def method_missing(method_name, *_args)
          raise_missing_ar!('Outbox', method_name)
        end

        def respond_to_missing?(_method_name, _include_private = false)
          false
        end

        private

        def raise_missing_ar!(which, method_name)
          raise(
            "#{which} requires ActiveRecord (tried to call ##{method_name}). " \
              'Enable `use_outbox` only in apps with ActiveRecord, or add ' \
              '`activerecord` to your Gemfile.'
          )
        end
      end
    end
  end
end
