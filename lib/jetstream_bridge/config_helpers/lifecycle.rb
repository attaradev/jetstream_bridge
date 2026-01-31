# frozen_string_literal: true

module JetstreamBridge
  module ConfigHelpers
    module Lifecycle
      module_function

      def setup(logger: nil, rails_app: nil)
        app = rails_app
        app ||= Rails.application if defined?(Rails) && Rails.respond_to?(:application)

        # Gracefully no-op when Rails isn't available (e.g., non-Rails runtimes or early boot)
        return unless app

        effective_logger = logger || default_rails_logger(app)

        app.config.after_initialize do
          JetstreamBridge.startup!
          effective_logger&.info('JetStream Bridge connected successfully')
        rescue StandardError => e
          effective_logger&.error("Failed to connect to JetStream: #{e.message}")
        end

        Kernel.at_exit { JetstreamBridge.shutdown! }
      end

      def default_rails_logger(app = nil)
        return app.logger if app.respond_to?(:logger)

        defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
      end
    end
  end
end
