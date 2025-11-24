# frozen_string_literal: true

module JetstreamBridge
  module TestHelpers
    # Common fixtures for quickly building events in specs.
    module Fixtures
      module_function

      # Build a user.created event
      def user_created_event(attrs = {})
        JetstreamBridge::TestHelpers.build_jetstream_event(
          event_type: 'user.created',
          payload: {
            id: attrs[:id] || 1,
            email: attrs[:email] || 'test@example.com',
            name: attrs[:name] || 'Test User'
          }.merge(attrs[:payload] || {})
        )
      end

      # Build multiple sample events
      def sample_events(count = 3, type: 'test.event')
        Array.new(count) do |i|
          JetstreamBridge::TestHelpers.build_jetstream_event(
            event_type: type,
            payload: { id: i + 1, sequence: i }
          )
        end
      end

      # Build a generic event with custom attributes
      def event(event_type:, payload: {}, **attrs)
        JetstreamBridge::TestHelpers.build_jetstream_event(
          event_type: event_type,
          payload: payload,
          **attrs
        )
      end
    end
  end
end
