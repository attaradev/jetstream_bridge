# frozen_string_literal: true

require_relative '../errors'

module JetstreamBridge
  # Configuration object for JetStream Bridge.
  #
  # Holds all configuration settings including NATS connection details,
  # application identifiers, reliability features, and consumer tuning.
  #
  # @example Basic configuration
  #   JetstreamBridge.configure do |config|
  #     config.nats_urls = "nats://localhost:4222"
  #     config.env = "production"
  #     config.app_name = "api_service"
  #     config.destination_app = "worker_service"
  #     config.use_outbox = true
  #     config.use_inbox = true
  #   end
  #
  # @example Using a preset
  #   JetstreamBridge.configure_for(:production) do |config|
  #     config.nats_urls = ENV["NATS_URLS"]
  #     config.app_name = "api"
  #     config.destination_app = "worker"
  #   end
  #
  class Config
    # Status constants for event processing states.
    module Status
      # Event queued in outbox, not yet published
      PENDING = 'pending'
      # Event currently being published to NATS
      PUBLISHING = 'publishing'
      # Event successfully published to NATS
      SENT = 'sent'
      # Event failed to publish after retries
      FAILED = 'failed'
      # Event received by consumer
      RECEIVED = 'received'
      # Event currently being processed by consumer
      PROCESSING = 'processing'
      # Event successfully processed by consumer
      PROCESSED = 'processed'
    end

    # NATS server URL(s), comma-separated for multiple servers
    # @return [String]
    attr_accessor :destination_app
    # NATS server URL(s)
    # @return [String]
    attr_accessor :nats_urls
    # Environment namespace (development, staging, production)
    # @return [String]
    attr_accessor :env
    # Application name for subject routing
    # @return [String]
    attr_accessor :app_name
    # Maximum delivery attempts before moving to DLQ
    # @return [Integer]
    attr_accessor :max_deliver
    # Time to wait for acknowledgment before redelivery
    # @return [String, Integer]
    attr_accessor :ack_wait
    # Backoff delays between retries
    # @return [Array<String>]
    attr_accessor :backoff
    # Enable transactional outbox pattern
    # @return [Boolean]
    attr_accessor :use_outbox
    # Enable idempotent inbox pattern
    # @return [Boolean]
    attr_accessor :use_inbox
    # ActiveRecord model class name for inbox events
    # @return [String]
    attr_accessor :inbox_model
    # ActiveRecord model class name for outbox events
    # @return [String]
    attr_accessor :outbox_model
    # Enable dead letter queue
    # @return [Boolean]
    attr_accessor :use_dlq
    # Logger instance
    # @return [Logger, nil]
    attr_accessor :logger
    # Applied preset name
    # @return [Symbol, nil]
    attr_reader :preset_applied
    # Number of retry attempts for initial connection
    # @return [Integer]
    attr_accessor :connect_retry_attempts
    # Delay between connection retry attempts (in seconds)
    # @return [Integer]
    attr_accessor :connect_retry_delay
    # Enable lazy connection (connect on first use instead of during configure)
    # @return [Boolean]
    attr_accessor :lazy_connect

    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      @env             = ENV['NATS_ENV']  || 'development'
      @app_name        = ENV['APP_NAME']  || 'app'
      @destination_app = ENV.fetch('DESTINATION_APP', nil)

      @max_deliver = 5
      @ack_wait    = '30s'
      @backoff     = %w[1s 5s 15s 30s 60s]

      @use_outbox   = false
      @use_inbox    = false
      @use_dlq      = true
      @outbox_model = 'JetstreamBridge::OutboxEvent'
      @inbox_model  = 'JetstreamBridge::InboxEvent'
      @logger       = nil
      @preset_applied = nil

      # Connection management
      @connect_retry_attempts = 3
      @connect_retry_delay = 2
      @lazy_connect = false
    end

    # Apply a configuration preset
    #
    # @param preset_name [Symbol, String] Name of preset (e.g., :production, :development)
    # @return [self]
    def apply_preset(preset_name)
      require_relative 'config_preset'
      ConfigPreset.apply(self, preset_name)
      @preset_applied = preset_name.to_sym
      self
    end

    # Get the JetStream stream name for this environment.
    #
    # @return [String] Stream name in format "{env}-jetstream-bridge-stream"
    # @example
    #   config.env = "production"
    #   config.stream_name  # => "production-jetstream-bridge-stream"
    def stream_name
      "#{env}-jetstream-bridge-stream"
    end

    # Get the NATS subject this application publishes to.
    #
    # Producer publishes to:   {env}.{app}.sync.{dest}
    # Consumer subscribes to:  {env}.{dest}.sync.{app}
    #
    # @return [String] Source subject for publishing
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components empty
    # @example
    #   config.env = "production"
    #   config.app_name = "api"
    #   config.destination_app = "worker"
    #   config.source_subject  # => "production.api.sync.worker"
    def source_subject
      validate_subject_component!(env, 'env')
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{env}.#{app_name}.sync.#{destination_app}"
    end

    # Get the NATS subject this application subscribes to.
    #
    # @return [String] Destination subject for consuming
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components empty
    # @example
    #   config.env = "production"
    #   config.app_name = "api"
    #   config.destination_app = "worker"
    #   config.destination_subject  # => "production.worker.sync.api"
    def destination_subject
      validate_subject_component!(env, 'env')
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{env}.#{destination_app}.sync.#{app_name}"
    end

    # Get the dead letter queue subject for this application.
    #
    # Each app has its own DLQ for better isolation and monitoring.
    #
    # @return [String] DLQ subject in format "{env}.{app_name}.sync.dlq"
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components are empty
    # @example
    #   config.env = "production"
    #   config.app_name = "api"
    #   config.dlq_subject  # => "production.api.sync.dlq"
    def dlq_subject
      validate_subject_component!(env, 'env')
      validate_subject_component!(app_name, 'app_name')
      "#{env}.#{app_name}.sync.dlq"
    end

    # Get the durable consumer name for this application.
    #
    # @return [String] Durable name in format "{env}-{app_name}-workers"
    # @example
    #   config.env = "production"
    #   config.app_name = "api"
    #   config.durable_name  # => "production-api-workers"
    def durable_name
      "#{env}-#{app_name}-workers"
    end

    # Validate all configuration settings.
    #
    # Checks that required settings are present and valid. Raises errors
    # for any invalid configuration.
    #
    # @return [true] If configuration is valid
    # @raise [ConfigurationError] If any validation fails
    # @example
    #   config.validate!  # Raises if destination_app is missing
    def validate!
      errors = []
      errors << 'destination_app is required' if destination_app.to_s.strip.empty?
      errors << 'nats_urls is required' if nats_urls.to_s.strip.empty?
      errors << 'env is required' if env.to_s.strip.empty?
      errors << 'app_name is required' if app_name.to_s.strip.empty?
      errors << 'max_deliver must be >= 1' if max_deliver.to_i < 1
      errors << 'backoff must be an array' unless backoff.is_a?(Array)
      errors << 'backoff must not be empty' if backoff.is_a?(Array) && backoff.empty?

      raise ConfigurationError, "Configuration errors: #{errors.join(', ')}" if errors.any?

      true
    end

    private

    def validate_subject_component!(value, name)
      str = value.to_s.strip
      raise MissingConfigurationError, "#{name} cannot be empty" if str.empty?

      # NATS subject tokens must not contain wildcards, spaces, or control characters
      # Valid characters: alphanumeric, hyphen, underscore
      if str.match?(/[.*>\s\x00-\x1F\x7F]/)
        raise InvalidSubjectError,
              "#{name} contains invalid NATS subject characters (wildcards, spaces, or control chars): #{value.inspect}"
      end

      # NATS has a practical subject length limit
      return unless str.length > 255

      raise InvalidSubjectError, "#{name} exceeds maximum length (255 characters): #{str.length}"
    end
  end
end
