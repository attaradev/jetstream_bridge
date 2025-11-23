# frozen_string_literal: true

require_relative 'core/model_codec_setup'
require_relative 'core/logging'

module JetstreamBridge
  # Rails integration for JetStream Bridge.
  #
  # This Railtie integrates JetStream Bridge with the Rails application lifecycle:
  # - Startup: Connection is established when Rails initializers run (via configure)
  # - Shutdown: Connection is closed when Rails shuts down (at_exit hook)
  # - Restart: Puma/Unicorn workers get fresh connections on fork
  #
  class Railtie < ::Rails::Railtie
    # Set up logger to use Rails.logger by default
    # Note: configure() will call startup! which establishes the connection
    initializer 'jetstream_bridge.logger', before: :initialize_logger do
      JetstreamBridge.configure do |config|
        config.logger ||= Rails.logger if defined?(Rails.logger)
      end
    end

    # Load ActiveRecord model tweaks after ActiveRecord is loaded
    initializer 'jetstream_bridge.active_record', after: 'active_record.initialize_database' do
      ActiveSupport.on_load(:active_record) do
        ActiveSupport::Reloader.to_prepare { JetstreamBridge::ModelCodecSetup.apply! }
      end
    end

    # Validate configuration and setup environment-specific behavior
    initializer 'jetstream_bridge.setup', after: :load_config_initializers do |app|
      app.config.after_initialize do
        # Validate configuration in development/test
        if Rails.env.development? || Rails.env.test?
          begin
            JetstreamBridge.config.validate! if JetstreamBridge.config.destination_app
          rescue JetstreamBridge::ConfigurationError => e
            Rails.logger.warn "[JetStream Bridge] Configuration warning: #{e.message}"
          end
        end

        # Auto-enable test mode in test environment if NATS_URLS not set
        if Rails.env.test? && ENV['NATS_URLS'].blank?
          unless defined?(JetstreamBridge::TestHelpers) &&
                 JetstreamBridge::TestHelpers.respond_to?(:test_mode?) &&
                 JetstreamBridge::TestHelpers.test_mode?
            Rails.logger.info '[JetStream Bridge] Auto-enabling test mode (NATS_URLS not set)'
            require_relative 'test_helpers'
            JetstreamBridge::TestHelpers.enable_test_mode!
          end
        end

        # Log helpful connection info in development
        if Rails.env.development? && JetstreamBridge.connected?
          conn_state = JetstreamBridge::Connection.instance.state
          Rails.logger.info "[JetStream Bridge] Connection state: #{conn_state}"
          Rails.logger.info "[JetStream Bridge] Connected to: #{JetstreamBridge.config.nats_urls}"
          Rails.logger.info "[JetStream Bridge] Stream: #{JetstreamBridge.config.stream_name}"
          Rails.logger.info "[JetStream Bridge] Publishing to: #{JetstreamBridge.config.source_subject}"
          Rails.logger.info "[JetStream Bridge] Consuming from: #{JetstreamBridge.config.destination_subject}"
        end
      rescue StandardError => e
        # Don't fail app initialization for logging errors
        Rails.logger.debug "[JetStream Bridge] Setup logging skipped: #{e.message}"
      end
    end

    # Register shutdown hook for graceful cleanup
    # This runs when Rails shuts down (Ctrl+C, SIGTERM, etc.)
    config.after_initialize do
      at_exit do
        JetstreamBridge.shutdown!
      end
    end

    # Add console helper methods
    console do
      Rails.logger.info "[JetStream Bridge] Loaded v#{JetstreamBridge::VERSION}"
      Rails.logger.info '[JetStream Bridge] Use JetstreamBridge.health_check to check status'
      Rails.logger.info '[JetStream Bridge] Use JetstreamBridge.shutdown! to gracefully disconnect'
    end

    # Load rake tasks
    rake_tasks do
      load File.expand_path('tasks/install.rake', __dir__)
    end

    # Add generators
    generators do
      require 'generators/jetstream_bridge/health_check/health_check_generator'
    end
  end
end
