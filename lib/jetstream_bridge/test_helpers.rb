# frozen_string_literal: true

require 'securerandom'

module JetstreamBridge
  # Test helpers for easier testing of JetStream Bridge integrations
  #
  # @example RSpec configuration
  #   require 'jetstream_bridge/test_helpers'
  #
  #   RSpec.configure do |config|
  #     config.include JetstreamBridge::TestHelpers
  #
  #     config.before(:each, :jetstream) do
  #       JetstreamBridge::TestHelpers.enable_test_mode!
  #     end
  #
  #     config.after(:each, :jetstream) do
  #       JetstreamBridge::TestHelpers.reset_test_mode!
  #     end
  #   end
  #
  # @example Using in tests
  #   RSpec.describe UserService, :jetstream do
  #     it "publishes user created event" do
  #       service.create_user(name: "Ada")
  #
  #       expect(JetstreamBridge).to have_published(
  #         event_type: "user.created",
  #         payload: hash_including(name: "Ada")
  #       )
  #     end
  #   end
  #
  module TestHelpers
    class << self
      # Enable test mode with in-memory event capture
      #
      # @return [void]
      def enable_test_mode!
        @test_mode = true
        @published_events = []
        @consumed_events = []
      end

      # Reset test mode and clear captured events
      #
      # @return [void]
      def reset_test_mode!
        @test_mode = false
        @published_events = []
        @consumed_events = []
      end

      # Check if test mode is enabled
      #
      # @return [Boolean]
      def test_mode?
        @test_mode ||= false
      end

      # Get all published events captured in test mode
      #
      # @return [Array<Hash>] Array of published event hashes
      def published_events
        @published_events ||= []
      end

      # Get all consumed events captured in test mode
      #
      # @return [Array<Hash>] Array of consumed event hashes
      def consumed_events
        @consumed_events ||= []
      end

      # Record a published event (called internally)
      #
      # @param event [Hash] Event data
      # @return [void]
      def record_published_event(event)
        @published_events ||= []
        @published_events << event.dup
      end

      # Record a consumed event (called internally)
      #
      # @param event [Hash] Event data
      # @return [void]
      def record_consumed_event(event)
        @consumed_events ||= []
        @consumed_events << event.dup
      end
    end

    # Build a test Event object
    #
    # @param event_type [String] Event type (e.g., "user.created")
    # @param payload [Hash] Event payload
    # @param event_id [String, nil] Optional event ID
    # @param trace_id [String, nil] Optional trace ID
    # @param occurred_at [Time, String, nil] Optional timestamp
    # @param metadata [Hash] Optional metadata
    # @return [Models::Event] Event object
    #
    # @example
    #   event = build_jetstream_event(
    #     event_type: "user.created",
    #     payload: { id: 1, email: "user@example.com" }
    #   )
    #   handler.call(event)
    #
    def build_jetstream_event(event_type:, payload:, event_id: nil, trace_id: nil, occurred_at: nil, **metadata)
      event_hash = {
        'event_id' => event_id || SecureRandom.uuid,
        'schema_version' => 1,
        'event_type' => event_type,
        'producer' => 'test',
        'resource_id' => (payload['id'] || payload[:id] || '').to_s,
        'occurred_at' => (occurred_at || Time.now.utc).iso8601,
        'trace_id' => trace_id || SecureRandom.hex(8),
        'resource_type' => event_type.split('.').first || 'event',
        'payload' => payload
      }

      Models::Event.new(
        event_hash,
        metadata: {
          subject: metadata[:subject] || 'test.subject',
          deliveries: metadata[:deliveries] || 1,
          stream: metadata[:stream] || 'test-stream',
          sequence: metadata[:sequence] || 1,
          consumer: metadata[:consumer] || 'test-consumer',
          timestamp: Time.now
        }
      )
    end

    # Simulate triggering an event to a consumer
    #
    # @param event [Models::Event, Hash] Event to trigger
    # @param handler [Proc, #call] Handler to call with event
    # @return [void]
    #
    # @example
    #   event = build_jetstream_event(event_type: "user.created", payload: { id: 1 })
    #   trigger_jetstream_event(event, ->(e) { process_event(e) })
    #
    def trigger_jetstream_event(event, handler = nil)
      handler ||= @handler if defined?(@handler)
      raise ArgumentError, 'handler is required' unless handler

      TestHelpers.record_consumed_event(event.to_h) if TestHelpers.test_mode?
      handler.call(event)
    end

    # RSpec matchers module
    #
    # @example Include in RSpec
    #   RSpec.configure do |config|
    #     config.include JetstreamBridge::TestHelpers
    #     config.include JetstreamBridge::TestHelpers::Matchers
    #   end
    #
    module Matchers
      # Matcher for checking if an event was published
      #
      # @param event_type [String] Event type to match
      # @param payload [Hash] Optional payload attributes to match
      # @return [HavePublished] Matcher instance
      #
      # @example
      #   expect(JetstreamBridge).to have_published(
      #     event_type: "user.created",
      #     payload: { id: 1 }
      #   )
      #
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

      # Matcher for checking publish result
      #
      # @example
      #   result = JetstreamBridge.publish(...)
      #   expect(result).to be_publish_success
      #
      def be_publish_success
        BePublishSuccess.new
      end

      # Matcher implementation for be_publish_success
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

      # Matcher for checking publish failure
      #
      # @example
      #   result = JetstreamBridge.publish(...)
      #   expect(result).to be_publish_failure
      #
      def be_publish_failure
        BePublishFailure.new
      end

      # Matcher implementation for be_publish_failure
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
