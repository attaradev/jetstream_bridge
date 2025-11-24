# frozen_string_literal: true

module JetstreamBridge
  module TestHelpers
    # RSpec matchers for asserting publish outcomes and captured events.
    module Matchers
      # Matcher for checking if an event was published
      #
      # @param event_type [String] Event type to match
      # @param payload [Hash] Optional payload attributes to match
      # @return [HavePublished] Matcher instance
      def have_published(event_type:, payload: {})
        HavePublished.new(event_type, payload)
      end

      # Matcher implementation for have_published
      class HavePublished
        def initialize(event_type, payload_attributes)
          @event_type = event_type
          @payload_attributes = payload_attributes
        end

        def matches?(_actual)
          TestHelpers.published_events.any? do |event|
            matches_event_type?(event) && matches_payload?(event)
          end
        end

        def failure_message
          "expected to have published event_type: #{@event_type.inspect} " \
            "with payload: #{@payload_attributes.inspect}\n" \
            "but found events: #{TestHelpers.published_events.map { |e| e['event_type'] }.inspect}"
        end

        def failure_message_when_negated
          "expected not to have published event_type: #{@event_type.inspect} " \
            "with payload: #{@payload_attributes.inspect}"
        end

        private

        def matches_event_type?(event)
          event['event_type'] == @event_type || event[:event_type] == @event_type
        end

        def matches_payload?(event)
          payload = event['payload'] || event[:payload] || {}
          @payload_attributes.all? do |key, value|
            payload_value = payload[key.to_s] || payload[key.to_sym]
            if value.is_a?(RSpec::Matchers::BuiltIn::BaseMatcher)
              value.matches?(payload)
            else
              payload_value == value
            end
          end
        end
      end

      # Matcher for checking publish result success
      def be_publish_success
        BePublishSuccess.new
      end

      class BePublishSuccess
        def matches?(actual)
          actual.respond_to?(:success?) && actual.success?
        end

        def failure_message
          'expected PublishResult to be successful but it failed'
        end

        def failure_message_when_negated
          'expected PublishResult to not be successful but it was'
        end
      end

      # Matcher for checking publish result failure
      def be_publish_failure
        BePublishFailure.new
      end

      class BePublishFailure
        def matches?(actual)
          actual.respond_to?(:failure?) && actual.failure?
        end

        def failure_message
          'expected PublishResult to be a failure but it succeeded'
        end

        def failure_message_when_negated
          'expected PublishResult to not be a failure but it was'
        end
      end
    end
  end
end
