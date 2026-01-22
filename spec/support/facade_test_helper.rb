# frozen_string_literal: true

# Test helper for mocking the Facade and ConnectionManager
module FacadeTestHelper
  # Set up mocks for JetstreamBridge to use a mock JetStream connection
  #
  # @param mock_jts [RSpec::Mocks::Double] Mock JetStream context
  # @param mock_nc [RSpec::Mocks::Double, nil] Optional mock NATS client
  def setup_facade_mocks(mock_jts, mock_nc: nil)
    # Create mock connection manager
    mock_connection_manager = instance_double(
      JetstreamBridge::ConnectionManager,
      jetstream: mock_jts,
      nats_client: mock_nc,
      connected?: true,
      connect!: nil,
      disconnect!: nil,
      health_check: {
        connected: true,
        state: :connected,
        connected_at: Time.now,
        last_error: nil,
        last_error_at: nil
      }
    )

    # Get or create the facade, preserving existing config
    facade = JetstreamBridge.instance_variable_get(:@facade)
    if facade.nil?
      facade = JetstreamBridge::Facade.new
      JetstreamBridge.instance_variable_set(:@facade, facade)
    end

    # Inject the mocked connection manager into the existing facade
    facade.instance_variable_set(:@connection_manager, mock_connection_manager)

    # Return both for use in tests
    { facade: facade, connection_manager: mock_connection_manager }
  end

  # Mark JetstreamBridge as connected (for tests that check @connection_initialized)
  def mark_as_connected
    # This is legacy - new architecture doesn't use this flag
    # But keeping for backward compatibility with existing tests
    JetstreamBridge.instance_variable_set(:@connection_initialized, true)
  end
end

RSpec.configure do |config|
  config.include FacadeTestHelper
end
