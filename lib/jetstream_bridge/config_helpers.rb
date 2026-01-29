# frozen_string_literal: true

require_relative 'core/logging'
require_relative 'core/config'

module JetstreamBridge
  # Convenience helpers to keep example configuration lean and consistent.
  module ConfigHelpers
    DEFAULT_STREAM = 'sync-stream'
    DEFAULT_BACKOFF = %w[1s 5s 15s 30s 60s].freeze
    DEFAULT_ACK_WAIT = '30s'
    DEFAULT_MAX_DELIVER = 5

    module_function

    # Configure a bidirectional bridge with sensible defaults.
    #
    # @param app_name [String] Name of the local app (publisher + consumer)
    # @param destination_app [String] Remote app to sync with
    # @param mode [Symbol] :non_restrictive (auto provision) or :restrictive
    # @param stream_name [String] JetStream stream name
    # @param nats_url [String] NATS connection URL(s)
    # @param use_outbox [Boolean] Enable transactional outbox pattern
    # @param use_inbox [Boolean] Enable idempotent inbox pattern
    # @param logger [Logger,nil] Logger to attach to configuration
    # @param overrides [Hash] Additional config overrides applied verbatim
    #
    # @yield [config] Optional block for further customization
    #
    # @return [JetstreamBridge::Config]
    def configure_bidirectional(
      app_name:,
      destination_app:,
      mode: :non_restrictive,
      stream_name: DEFAULT_STREAM,
      nats_url: ENV.fetch('NATS_URL', 'nats://nats:4222'),
      use_outbox: true,
      use_inbox: true,
      logger: nil,
      **overrides
    )
      JetstreamBridge.configure do |config|
        apply_base_settings(config, app_name, destination_app, stream_name, nats_url, use_outbox, use_inbox, mode,
                            overrides)
        apply_reliability_defaults(config, overrides)
        config.logger = logger if logger
        apply_overrides(config, overrides)
        yield(config) if block_given?

        config
      end
    end

    # Wire JetstreamBridge lifecycle into Rails boot/shutdown.
    #
    # Safe to call multiple times; startup! is idempotent.
    #
    # @param logger [Logger,nil] Logger to use for lifecycle messages
    # @return [void]
    def setup_rails_lifecycle(logger: nil, rails_app: nil)
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

    def restrictive?(mode)
      mode.to_sym == :restrictive
    end
    private_class_method :restrictive?

    def apply_base_settings(config, app_name, destination_app, stream_name, nats_url, use_outbox, use_inbox, mode,
                            overrides)
      config.nats_urls = nats_url
      config.app_name = app_name
      config.destination_app = destination_app
      config.stream_name = stream_name
      config.auto_provision = !restrictive?(mode)
      config.use_outbox = use_outbox
      config.use_inbox = use_inbox
      config.consumer_mode = overrides.fetch(:consumer_mode, config.consumer_mode || :pull)
    end
    private_class_method :apply_base_settings

    def apply_reliability_defaults(config, overrides)
      config.max_deliver = overrides.fetch(:max_deliver, DEFAULT_MAX_DELIVER)
      config.ack_wait = overrides.fetch(:ack_wait, DEFAULT_ACK_WAIT)
      config.backoff = overrides.fetch(:backoff, DEFAULT_BACKOFF)
    end
    private_class_method :apply_reliability_defaults

    def apply_overrides(config, overrides)
      ignored = [:max_deliver, :ack_wait, :backoff, :consumer_mode]
      overrides.each do |key, value|
        next if ignored.include?(key)

        setter = "#{key}="
        config.public_send(setter, value) if config.respond_to?(setter)
      end
    end
    private_class_method :apply_overrides

    def default_rails_logger(app = nil)
      return app.logger if app.respond_to?(:logger)

      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end
    private_class_method :default_rails_logger
  end
end
