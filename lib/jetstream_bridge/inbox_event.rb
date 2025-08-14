# frozen_string_literal: true

begin
  require 'active_record'
rescue LoadError
  # Ignored
end

module JetstreamBridge
  if defined?(ActiveRecord::Base)
    class InboxEvent < ActiveRecord::Base
      self.table_name = 'jetstream_inbox_events'
    end
  else
    class InboxEvent
      def self.method_missing(*)
        raise 'JetstreamBridge Inbox requires ActiveRecord. '\
                'Enable `use_inbox` only in apps with ActiveRecord, '\
                'or add `activerecord` to your Gemfile.'
      end

      def self.respond_to_missing?(*)
        false
      end
    end
  end
end
