# frozen_string_literal: true

require_relative 'core/model_codec_setup'
require_relative 'core/logging'

module JetstreamBridge
  class Railtie < ::Rails::Railtie
    # Set up logger to use Rails.logger by default
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

    # Validate configuration in development/test
    initializer 'jetstream_bridge.validate_config', after: :load_config_initializers do |app|
      if Rails.env.development? || Rails.env.test?
        app.config.after_initialize do
          JetstreamBridge.config.validate! if JetstreamBridge.config.destination_app
        rescue JetstreamBridge::ConfigurationError => e
          Rails.logger.warn "[JetStream Bridge] Configuration warning: #{e.message}"
        end
      end
    end

    # Add console helper methods
    console do
      Rails.logger.info "[JetStream Bridge] Loaded v#{JetstreamBridge::VERSION}"
      Rails.logger.info '[JetStream Bridge] Use JetstreamBridge.health_check to check status'
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
