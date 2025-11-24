# frozen_string_literal: true

require_relative '../core/model_codec_setup'
require_relative '../core/logging'
require_relative '../core/connection'

module JetstreamBridge
  module Rails
    # Rails-specific lifecycle helpers for JetStream Bridge.
    #
    # Keeps the Railtie thin and makes lifecycle decisions easy to test and reason about.
    module Integration
      module_function

      # Configure logger to use Rails.logger when available.
      def configure_logger!
        JetstreamBridge.configure do |config|
          config.logger ||= ::Rails.logger if defined?(::Rails.logger)
        end
      end

      # Attach ActiveRecord hooks for serializer setup on reload.
      def attach_active_record_hooks!
        ActiveSupport.on_load(:active_record) do
          ActiveSupport::Reloader.to_prepare { JetstreamBridge::ModelCodecSetup.apply! }
        end
      end

      # Validate config, enable test mode if appropriate, and start the bridge unless auto-start is disabled.
      def boot_bridge!
        auto_enable_test_mode!

        if autostart_disabled?
          message = "Auto-start skipped (reason: #{autostart_skip_reason}; " \
                    'enable via lazy_connect=false, unset JETSTREAM_BRIDGE_DISABLE_AUTOSTART, ' \
                    'or set JETSTREAM_BRIDGE_FORCE_AUTOSTART=1)'
          Logging.info(message, tag: 'JetstreamBridge::Railtie')
          return
        end

        JetstreamBridge.config.validate!
        JetstreamBridge.startup!
        log_started!
        log_development_connection_details! if rails_development?
        register_shutdown_hook!
      end

      # Auto-enable test mode in test environment when NATS is not configured.
      def auto_enable_test_mode!
        return unless auto_enable_test_mode?

        Logging.info(
          '[JetStream Bridge] Auto-enabling test mode (NATS_URLS not set)',
          tag: 'JetstreamBridge::Railtie'
        )

        require_relative '../test_helpers'
        JetstreamBridge::TestHelpers.enable_test_mode!
      end

      def auto_enable_test_mode?
        rails_test? &&
          ENV['NATS_URLS'].to_s.strip.empty? &&
          !(defined?(JetstreamBridge::TestHelpers) &&
            JetstreamBridge::TestHelpers.respond_to?(:test_mode?) &&
            JetstreamBridge::TestHelpers.test_mode?)
      end

      def autostart_disabled?
        return false if force_autostart?

        JetstreamBridge.config.lazy_connect ||
          env_disables_autostart? ||
          skip_autostart_for_rails_tooling?
      end

      def autostart_skip_reason
        return 'lazy_connect enabled' if JetstreamBridge.config.lazy_connect
        return 'JETSTREAM_BRIDGE_DISABLE_AUTOSTART set' if env_disables_autostart?
        return 'Rails console' if rails_console?
        return 'rake task' if rake_task?

        'unknown'
      end

      def env_disables_autostart?
        value = ENV.fetch('JETSTREAM_BRIDGE_DISABLE_AUTOSTART', nil)
        return false if value.nil?

        normalized = value.to_s.strip.downcase
        return false if normalized.empty?

        !%w[false 0 no off].include?(normalized)
      end

      def force_autostart?
        value = ENV.fetch('JETSTREAM_BRIDGE_FORCE_AUTOSTART', nil)
        return false if value.nil?

        normalized = value.to_s.strip.downcase
        %w[true 1 yes on].include?(normalized)
      end

      def log_started!
        active_logger&.info('[JetStream Bridge] Started successfully')
      end

      def log_development_connection_details!
        conn_state = JetstreamBridge::Connection.instance.state
        active_logger&.info("[JetStream Bridge] Connection state: #{conn_state}")
        active_logger&.info("[JetStream Bridge] Connected to: #{JetstreamBridge.config.nats_urls}")
        active_logger&.info("[JetStream Bridge] Stream: #{JetstreamBridge.config.stream_name}")
        active_logger&.info("[JetStream Bridge] Publishing to: #{JetstreamBridge.config.source_subject}")
        active_logger&.info("[JetStream Bridge] Consuming from: #{JetstreamBridge.config.destination_subject}")
      end

      def register_shutdown_hook!
        return if @shutdown_hook_registered

        at_exit { JetstreamBridge.shutdown! }
        @shutdown_hook_registered = true
      end

      def rails_test?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.test?
      end

      def rails_development?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development?
      end

      def rails_console?
        !!defined?(::Rails::Console)
      end

      def rake_task?
        !!defined?(::Rake) || File.basename($PROGRAM_NAME) == 'rake'
      end

      def skip_autostart_for_rails_tooling?
        rails_console? || rake_task?
      end

      def active_logger
        if defined?(::Rails) && ::Rails.respond_to?(:logger)
          ::Rails.logger
        else
          Logging.logger
        end
      end
    end
  end
end
