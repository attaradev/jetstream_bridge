# frozen_string_literal: true

require 'securerandom'
require_relative 'test_helpers/mock_nats'
require_relative 'test_helpers/matchers'
require_relative 'test_helpers/fixtures'
require_relative 'test_helpers/integration_helpers'

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
      # Auto-configure test helpers when RSpec is detected
      #
      # This method is called automatically when test_helpers.rb is required.
      # It sets up RSpec configuration to enable test mode for tests tagged with :jetstream.
      #
      # @return [void]
      def auto_configure!
        return unless defined?(RSpec)
        return if @configured

        RSpec.configure do |config|
          config.include JetstreamBridge::TestHelpers
          config.include JetstreamBridge::TestHelpers::Matchers

          config.before(:each, :jetstream) do
            JetstreamBridge::TestHelpers.enable_test_mode!
          end

          config.after(:each, :jetstream) do
            JetstreamBridge::TestHelpers.reset_test_mode!
          end
        end

        @configured = true
      end

      # Check if auto-configuration has been applied
      #
      # @return [Boolean]
      def configured?
        @configured ||= false
      end

      # Enable test mode with in-memory event capture and mock NATS connection
      #
      # @param use_mock_nats [Boolean] Whether to use mock NATS connection (default: true)
      # @return [void]
      def enable_test_mode!(use_mock_nats: true)
        @test_mode = true
        @published_events = []
        @consumed_events = []
        @mock_nats_enabled = use_mock_nats

        setup_mock_nats if use_mock_nats
      end

      # Reset test mode and clear captured events
      #
      # @return [void]
      def reset_test_mode!
        @test_mode = false
        @published_events = []
        @consumed_events = []

        teardown_mock_nats if @mock_nats_enabled
        @mock_nats_enabled = false
      end

      # Setup mock NATS connection
      #
      # @return [void]
      def setup_mock_nats
        MockNats.reset!
        @mock_connection = MockNats.create_mock_connection
        @mock_connection.connect

        # Store the mock for Connection to use
        JetstreamBridge.instance_variable_set(:@mock_nats_client, @mock_connection)
      end

      # Teardown mock NATS connection
      #
      # @return [void]
      def teardown_mock_nats
        MockNats.reset!
        @mock_connection = nil
        return unless JetstreamBridge.instance_variable_defined?(:@mock_nats_client)

        JetstreamBridge.remove_instance_variable(:@mock_nats_client)
      end

      # Get the current mock connection
      #
      # @return [MockNats::MockConnection, nil]
      attr_reader :mock_connection

      # Get the mock storage for direct access in tests
      #
      # @return [MockNats::InMemoryStorage]
      def mock_storage
        MockNats.storage
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
    module_function :build_jetstream_event

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
  end
end

# Auto-configure when loaded (only if RSpec is available)
JetstreamBridge::TestHelpers.auto_configure! if defined?(RSpec)
