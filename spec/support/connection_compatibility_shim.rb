# frozen_string_literal: true

# Backward compatibility shim for tests using the old Connection singleton pattern.
# This allows existing tests to continue working without extensive refactoring.
#
# The old architecture: JetstreamBridge::Connection (singleton)
# The new architecture: JetstreamBridge::Facade + ConnectionManager
#
# This shim provides the old Connection interface but is intentionally simple -
# it's primarily used for RSpec mocking, so the actual implementation doesn't matter.

module JetstreamBridge
  class Connection
    class << self
      @singleton__instance__ = nil

      attr_accessor :singleton__instance__

      # These methods are no-ops because they're only called when mocked by RSpec.
      # The actual functionality is provided by the Facade/ConnectionManager.
      def connect!
        nil
      end

      def jetstream
        nil
      end

      def nc
        nil
      end

      def instance
        @singleton__instance__ || MockConnectionInstance.new
      end
    end

    # Mock instance for tests that call Connection.instance
    class MockConnectionInstance
      def connected?
        # Delegate to the facade
        JetstreamBridge.connected?
      end

      def disconnect!
        JetstreamBridge.disconnect!
      end
    end
  end
end
