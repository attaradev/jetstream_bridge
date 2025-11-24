# frozen_string_literal: true

require_relative 'integration'

module JetstreamBridge
  # Rails integration for JetStream Bridge.
  #
  # This Railtie integrates JetStream Bridge with the Rails application lifecycle:
  # - Configuration: Logger is configured early in the Rails boot process
  # - Startup: Connection is established after user initializers load (explicit startup!)
  # - Shutdown: Connection is closed when Rails shuts down (at_exit hook)
  # - Restart: Puma/Unicorn workers get fresh connections on fork
  #
  class Railtie < ::Rails::Railtie
    # Set up logger to use Rails.logger by default
    # Note: This only configures the logger, does NOT establish connection
    initializer 'jetstream_bridge.logger', before: :initialize_logger do
      JetstreamBridge::Rails::Integration.configure_logger!
    end

    # Load ActiveRecord model tweaks after ActiveRecord is loaded
    initializer 'jetstream_bridge.active_record', after: 'active_record.initialize_database' do
      JetstreamBridge::Rails::Integration.attach_active_record_hooks!
    end

    # Establish connection after Rails initialization is complete
    # This runs after all user initializers have loaded
    config.after_initialize do
      JetstreamBridge::Rails::Integration.boot_bridge!
    end

    # Add console helper methods
    console do
      ::Rails.logger.info "[JetStream Bridge] Loaded v#{JetstreamBridge::VERSION}"
      ::Rails.logger.info '[JetStream Bridge] Console helpers available:'
      ::Rails.logger.info '  JetstreamBridge.health_check     - Check connection status'
      ::Rails.logger.info '  JetstreamBridge.stream_info      - View stream details'
      ::Rails.logger.info '  JetstreamBridge.connected?       - Check if connected'
      ::Rails.logger.info '  JetstreamBridge.shutdown!        - Gracefully disconnect'
      ::Rails.logger.info '  JetstreamBridge.reconnect!       - Reconnect (useful after configuration changes)'
    end

    # Load rake tasks
    rake_tasks do
      load File.expand_path('../tasks/install.rake', __dir__)
    end

    # Add generators
    generators do
      require 'generators/jetstream_bridge/health_check/health_check_generator'
    end
  end
end
